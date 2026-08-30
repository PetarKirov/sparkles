# `hue` picker — Feature Requirements (fuzzy finding, all interactive backends)

_**Status:** partial — F0 engine verified and P0 component/scheduler seams
implemented · **Date:** 2026-08-17 · **Scope:** hue's **picker** — the
fuzzy finder behind `<leader>f`, `<leader>s`, `<leader>g` and `<leader>/`
([lantern `LMP7`/`LMP8`](./lantern.md)) — its query language, its sources, its
ranking, and the `sparkles:fuzzy` engine underneath._

> [!NOTE]
> The bounded engine, files finder, presentation-free state, raw-pool scheduler,
> and shared widget tree exist; `<leader>ff` mounts the picker in both live
> hosts, and the preview panel hosts a real document pane over the same loader.
> Persistence, actions, and the later sources remain milestone work. Status
> legend and ID conventions: see the [overview](./index.md).

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

A grep over a large repository cannot block a frame. Every picker generation
therefore owns an immutable query arena, corpus snapshot, global top-K
accumulator, and cursor. The hue adapter takes a real monotonic **duration
budget** and advances the pure fuzzy engine one candidate-sized bounded call at
a time. It returns globally ranked partial results plus a cursor bound to the
generation, corpus snapshot, sink epoch, and accumulator revision.

The fan-out runs on `sparkles:event-horizon`'s fixed-capacity raw CPU-job pool —
the persistent, closure-free companion to the measured `cpuBound`
`WorkStealingPool` that
[beats rayon on `polyglot-walks`](../event-horizon/benchmarks.md) (1.16× on a
real 325k-entry tree, 4.26× on dense ones, 55 futex calls against
`std.parallelism`'s 10 632). Reusing it means the picker inherits a walker that
has already been measured against the best in the field.

> [!WARNING]
> Pool start or job submission can fail explicitly. Queue saturation runs the
> same bounded step synchronously; an unavailable platform uses a fully
> synchronous budget-stepped walk rather than losing the feature.

## The component (`PIK`)

| ID     | Requirement                                                                                                                                                                                                               | Status              | Traces to                                                                                    |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------- | -------------------------------------------------------------------------------------------- |
| `PIK1` | A **picker** must present a prompt, a ranked result list, and an optional preview, over any source — one component, many sources, in the shape fzf-lua and snacks.picker share.                                           | full                | `picker_host.d` + `picker_preview.d`, mounted in both hosts                                  |
| `PIK2` | Its state must be a **presentation-free value** — a fixed-capacity prompt editor, the scored items, selection and scroll offset — testable with no canvas, like every other `STM` machine.                                | full (working tree) | `PickerPrompt`, `PickerState`, `ScrollState`                                                 |
| `PIK3` | The view must be a **`sparkles:ui` widget tree**, painted by GUI and TUI from one definition (`UIA2`) — the contract [lantern `LTN5`](./lantern.md) is already held to.                                                   | full                | `picker_view.d`, painted by both hosts; grid readback in `workspace.leaderFfMountsThePicker` |
| `PIK4` | A **source** must be a DbI seam: anything that can produce items incrementally is a source, and adding one must not touch the component.                                                                                  | full (working tree) | `isFinder`, `finderSnapshot`, `FilesFinder`                                                  |
| `PIK5` | Every search must take a real monotonic **duration budget** and return partial globally-ranked results plus a cursor bound to generation, corpus snapshot, sink epoch, and accumulator revision.                          | full (working tree) | `searchChunk`; `PickerScheduler`                                                             |
| `PIK6` | Query/corpus arenas and result accumulators are caller-owned, fixed-capacity, immutable while borrowed, and pinned until all generation jobs complete; the search-scheduling path for a keystroke performs no allocation. | full (working tree) | fixed query/glob arena, generation slots, `TopK`                                             |
| `PIK7` | Re-running a query must cancel in-flight work with a monotonic atomic generation (release publication/acquire read); stale jobs cannot append to a new sink epoch.                                                        | full (working tree) | `PickerScheduler` + stale-generation tests                                                   |
| `PIK8` | The picker must **degrade** to a synchronous budget-stepped walk when the raw CPU pool cannot start or accept a job, rather than being unavailable.                                                                       | full (working tree) | `RawCpuPool` submission + synchronous fallback                                               |
| `PIK9` | `resume` must reopen the last picker with its query and selection intact.                                                                                                                                                 | not started         | proposed session store                                                                       |

## The query language (`PKQ`)

| ID     | Requirement                                                                                                                                                      | Status              | Traces to                       |
| ------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------- | ------------------------------- |
| `PKQ1` | A query must split into **constraints** plus a fuzzy remainder, in one pass, with every span **borrowed** from the input so parsing allocates nothing.           | full (working tree) | `sparkles.fuzzy.query`          |
| `PKQ2` | Constraints must cover `*.ext`, a **glob**, a path segment, a file path suffix, and `git:<status>` (`modified`/`staged`/`untracked`/`ignored`).                  | full (working tree) | compiled constraint evaluator   |
| `PKQ3` | Any actual constraint must be **negatable** (`!seg:test`, `!*.rs`); ordinary fuzzy text, `!=`, and `!!foo` remain literal.                                       | full (working tree) | deterministic dispatch + tests  |
| `PKQ4` | A trailing **`:line[:col]`** must parse as a location, so pasting `src/app.d:120` from a compiler diagnostic opens where it points.                              | full (working tree) | `Location`; Windows-drive guard |
| `PKQ5` | The matcher must be **typo-resistant**, not merely subsequence-based — a transposition or a dropped character must still rank, which is the difference from fzf. | full (working tree) | exact bounded-deletion witness  |
| `PKQ6` | Match **positions** must be returned so the list can highlight what matched.                                                                                     | full (working tree) | canonical merged byte ranges    |

## Ranking (`PKR`)

| ID     | Requirement                                                                                                                                                                                                      | Status                        | Traces to                                                          |
| ------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------- | ------------------------------------------------------------------ |
| `PKR1` | Results must be ranked by the **composite formula** above — a fuzzy base plus frecency, git status, path distance, filename quality and path alignment — not by match score alone.                               | full (working tree)           | `sparkles.fuzzy.rank`                                              |
| `PKR2` | **Frecency** must decay exponentially (a 10-day half-life over a 30-day window, capped at 128 timestamps per file), so recently and repeatedly opened files rank above cold ones.                                | full in memory (working tree) | fixed Q16 `FrecencyTable`                                          |
| `PKR3` | A **query-history combo boost** must rank a file the same query previously opened.                                                                                                                               | full in memory (working tree) | bounded `ComboTable`                                               |
| `PKR4` | Every result must carry its **score breakdown**, and a debug toggle must show it — a ranking nobody can inspect is one nobody can fix.                                                                           | full                          | `Command.pickerToggleScore` (`Ctrl-S`), handled in `picker_host.d` |
| `PKR5` | Frecency and query history must **persist** through the [configuration](./config.md) layer's state directory, not a second storage mechanism, and must never make hue fail to start.                             | not started                   | `sparkles:wired`; `common_dirs`                                    |
| `PKR6` | The persistence read/write is the one place `@nogc` is not required (it is startup/shutdown I/O, the [`NFR1`](./feature-requirements.md) carve-out); the in-memory table and every scoring path must be `@nogc`. | partial                       | in-memory path ships; persistence I/O pending                      |

## Sources (`PKS`)

Each row is one `<leader>` binding. **The map does not yet reserve them all**: `<leader>f` is a group with `<leader>ff` bound, but `<leader>/`, `<leader>s` and `<leader>g` are unclaimed at the leader level, so each source must add its own binding as it lands (`LMP7`/`LMP8`).

| ID      | Source         | Key          | Requirement                                                                                                         | Status                                                                |
| ------- | -------------- | ------------ | ------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------- |
| `PKS1`  | files          | `<leader>ff` | The `.gitignore`-aware walk, searched on the raw CPU pool, honouring the tree pane's include/exclude globs.         | partial — bound and mounted in both hosts; corpus walk is synchronous |
| `PKS2`  | grep           | `<leader>/`  | Content search in three modes — plain, regex, fuzzy — auto-detected, falling back to fuzzy on zero hits.            | not started                                                           |
| `PKS3`  | recent         | `<leader>fr` | Frecency-ordered previously opened documents (`PKR2`).                                                              | not started                                                           |
| `PKS4`  | open documents | `<leader>,`  | The current `SourceSet` ([`SRC6`](./feature-requirements.md)) — the substrate the [tab view](./tab-view.md) shares. | not started                                                           |
| `PKS5`  | git status     | `<leader>gs` | Changed files, from the existing cache rather than a new `git` invocation.                                          | not started                                                           |
| `PKS6`  | git commits    | `<leader>gc` | Commits, opening the revision as a [diff session](./diff-view.md).                                                  | not started                                                           |
| `PKS7`  | themes         | `<leader>st` | The built-in theme list ([`THM2`](./feature-requirements.md)), applying live as the selection moves.                | not started                                                           |
| `PKS8`  | lines          | `<leader>sl` | Lines of the current document — the in-document search, as a picker.                                                | not started                                                           |
| `PKS9`  | keymaps        | `<leader>sk` | `hueBindings` itself. Free once the table exists ([`KEY3`](./lantern.md)), and the honest test of `PIK4`.           | not started                                                           |
| `PKS10` | git files      | `<leader>fg` | Tracked files only, skipping the walk where a repository can answer faster.                                         | not started                                                           |

## Layout & actions (`PKL`)

| ID     | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                          | Status      | Traces to                                                                                                                            |
| ------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `PKL1` | Layouts must be selectable: `default` (list + preview side by side), `vscode` (a centred dropdown, no preview), `select` (small, for a short list).                                                                                                                                                                                                                                                                                                  | partial     | all presets exist in shared tree; final sizing/host mount pending                                                                    |
| `PKL2` | The **preview** must reuse `DocumentPipeline.load` and `ViewerModel` — the picker introduces no second rendering path.                                                                                                                                                                                                                                                                                                                               | full        | `picker_preview.d`: a `PreviewTui` over the host's own loader                                                                        |
| `PKL3` | Actions must be **bindings in the one table** ([`KEY1`](../ui/keymap.md)), so the guide lists what a picker's keys do exactly as it lists everything else.                                                                                                                                                                                                                                                                                           | full        | `hueBindings` `picker*` scopes; `keymap.pickerScopesAreModalAndFocusRouted`                                                          |
| `PKL4` | Rows must be **tappable**, and the prompt must accept the soft keyboard, so the picker is usable on Android where the leader menu is the only command surface.                                                                                                                                                                                                                                                                                       | not started | [android.md](./android.md)                                                                                                           |
| `PKL5` | `<S-Tab>` must cycle the grep mode, with the active mode shown; a single-mode configuration must hide the indicator. (Today `Shift-Tab` reverses the pane focus, `PKL7`; a grep source claims it back with a context-gated row when `P4` lands.)                                                                                                                                                                                                     | not started | fff.nvim's affordance                                                                                                                |
| `PKL6` | A grep result must classify **definition lines** (`struct`/`fn`/`class`/`def`/`impl`), so a definition can be ranked and marked above a mention.                                                                                                                                                                                                                                                                                                     | not started | fff's classifier                                                                                                                     |
| `PKL7` | The picker's panes must have a **focus model** (the snacks.picker shape, framework-owned — [`FOC2`/`FOC4`](../ui/keymap.md)): prompt/list/preview cycled by `Tab`, per-pane key routing from the one table, focus-dependent chrome (highlight border, accent title, caret only in the prompt, selection bar dims under a focused preview), a printable always a query edit, and a focused preview forwarding unbound keys to the real document pane. | full        | `PickerHost.focus` (`ScopeFocus`); `picker_view` chrome; `picker.host.focusCyclesAndRoutesKeys`; `workspace.leaderFfMountsThePicker` |

## The grep source (`PKC`)

`PKS2`'s design, grounded in the
[full-text-search research catalog](../../research/full-text-search/index.md)
and its [recommendations](../../research/full-text-search/recommendations.md).
The rows are `P4`'s contract; the prose is why they read the way they do.

### Two facts that shape everything

The grep source cannot be a new `Finder` corpus with content lines standing in
for paths, which is the obvious design and the wrong one:

1. **`searchChunk` is pure and clock-free**, so it cannot read a file. Scanning
   is I/O and must therefore live outside it.
2. **`validateCandidate` forces `filenameOffset == 0`** on anything it admits,
   and `rank` pays a filename bonus keyed off that offset. Feeding content lines
   through it makes _every_ line collect the bonus — the ranking is not merely
   tuned wrong, it is **arithmetically wrong**.

So the grep source owns its scan, its matching and its scoring, and re-enters
the shared picker only where results are already `RankedResult`s in a `TopK`.
That boundary is the design, and `PKC1` states it.

### The corpus is not just the walk

A hue session's documents may exist **only in memory** — `hue pr` builds them
from a forge payload, and git-history browsing will build them from object
content. Neither has a path on disk to read. Grep therefore addresses a
**document**, not a file, and the walk is one provider among several rather
than the definition of the corpus.

This is also why `resolve` must return a location rather than a path: opening a
grep hit means "this document, this line, this column", and for an in-memory
document there is no path that would say the same thing.

### Modes, and how one is chosen

Three modes — plain, regex, fuzzy — **classified once** from the query, with a
single visible fallback rung when a mode finds nothing. Not a ladder that tries
each in turn: a silent re-interpretation of the query makes the result list
unexplainable, and the mode indicator (`PKL5`) exists precisely so the user can
see which question was asked.

Regex is a **re-hosting, not a rewrite**. `std.regex`'s Pike VM already runs on
one `enforceMalloc` block with a preallocated thread freelist and `GC.addRange`
over only the class header; what blocks `@safe pure nothrow @nogc` is the
compiler, a process-global cache, an OOM throw and the `dip1000` `scope`
refusal — **none of it the matching loop**. Scope is seventeen of thirty
opcodes, dropping captures, backreferences and lookaround, which is the same
refusal every guaranteeing engine makes and the source of the time bound.

Because that is the one part with real schedule risk, `poolEligible(GrepMode)`
exists **from the first commit**, not retrofitted: if the regex arm cannot be
`@nogc`, one mode loses the pool and the design survives.

### Requirements

| ID      | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                                                                   | Status      | Traces to                                                                                                                            |
| ------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ------------------------------------------------------------------------------------------------------------------------------------ |
| `PKC1`  | The grep source must own its scan, matching and scoring, re-entering the shared picker only with ranked results. Content lines must **never** pass through `validateCandidate`/`rank`, whose `filenameOffset == 0` invariant would award every line the filename bonus.                                                                                                                                                                                                                       | not started | `sparkles.fuzzy.common`; `sparkles.fuzzy.rank`                                                                                       |
| `PKC2`  | The corpus must be a **provider seam** — the repository walk plus the session's in-memory documents — not the walk alone. A document with no path on disk (`hue pr`, git history) must be searchable.                                                                                                                                                                                                                                                                                         | not started | [`SRC6`](./feature-requirements.md)                                                                                                  |
| `PKC3`  | A result must be addressed as a **document handle plus line and column**, so `resolve` names a location rather than a path. Accepting a row must open at that location.                                                                                                                                                                                                                                                                                                                       | not started | `PickerTarget`; `ViewerModel.gotoSrcLine`                                                                                            |
| `PKC4`  | The files and grep sources must share **one** repository walk. Two walks would disagree about what exists the moment the tree changed between them.                                                                                                                                                                                                                                                                                                                                           | not started | `globWalkGitRepository`; `PKS1`                                                                                                      |
| `PKC5`  | The grep target is the document's **raw source**, not its rendered rows — the same haystack the in-document search settled on ([`FND2`](./viewer.md)).                                                                                                                                                                                                                                                                                                                                        | not started | [viewer.md](./viewer.md)                                                                                                             |
| `PKC6`  | Binary content must be excluded by the `isRenderable` path filter first, then by a NUL / invalid-UTF-8 sniff **over bytes already read** — never a second read.                                                                                                                                                                                                                                                                                                                               | not started | [hypergrep](../../research/full-text-search/hypergrep.md)                                                                            |
| `PKC7`  | Files must be read whole, **capped** — 1 MiB by default, configurable to 10 MiB. The cap is lower than a cached grep's because hue re-reads per query where fff caches. Memory-mapping is refused: a file changing under a map is a fault, not an error.                                                                                                                                                                                                                                      | not started | [fff-grep](../../research/full-text-search/fff-grep.md); [ripgrep](../../research/full-text-search/ripgrep.md)                       |
| `PKC8`  | Character classes must be **ASCII by default**, with Unicode available later and switchable at runtime — not a compile-time fork of the engine.                                                                                                                                                                                                                                                                                                                                               | not started | `SearchSettings`                                                                                                                     |
| `PKC9`  | The mode must be **classified once** from the query, with exactly one visible fallback rung. A silently re-interpreted query produces a result list nobody can explain.                                                                                                                                                                                                                                                                                                                       | not started | `PKL5`                                                                                                                               |
| `PKC10` | A work unit is **one whole file**, and generation cancellation must be polled **every file**. fff's "refuse to abort before two matches" rule must **not** be ported — hue already publishes ranked partial pages, so the reason for it does not hold here.                                                                                                                                                                                                                                   | not started | [interactive-contracts](../../research/full-text-search/interactive-contracts.md)                                                    |
| `PKC11` | A row must store a **512-byte window** around the match with elision, leading whitespace trimmed while the reported column stays true, plus the match ranges. 512 bytes keeps a line inside `maxDpUnits`, so scoring never silently degrades.                                                                                                                                                                                                                                                 | not started | fff's `GrepMatch`                                                                                                                    |
| `PKC12` | A row's identity must mix **path, line and column**. A `fingerprint()` keyed on the path alone collides across every hit in a file and freezes the list.                                                                                                                                                                                                                                                                                                                                      | not started | `sparkles.fuzzy.TopK`                                                                                                                |
| `PKC13` | Ranking must be **structural, not statistical**: the existing composite formula plus a definition-versus-mention term. BM25 is refused — term frequency is an anti-signal in code, IDF is distorted by generated files, and length normalisation punishes the short focused files people want.                                                                                                                                                                                                | not started | [ranked-retrieval](../../research/full-text-search/theory/ranked-retrieval.md)                                                       |
| `PKC14` | `PKL6`'s definition classifier must be a **byte heuristic during the scan**, refined by tree-sitter on the selected row only — from the parse the preview already performed. Do the expensive classification once, where it is affordable, and let the cheap one rank.                                                                                                                                                                                                                        | not started | [zoekt](../../research/full-text-search/trigram-indexes/zoekt.md)                                                                    |
| `PKC15` | `poolEligible(GrepMode)` must exist from the first commit, so a mode that cannot be `@nogc` degrades **that mode** rather than the design.                                                                                                                                                                                                                                                                                                                                                    | not started | `RawCpuPool`                                                                                                                         |
| `PKC16` | The regex mode must be a **bounded** engine — leftmost-first, no captures, no backreferences, no lookaround, counted repetition expanded at compile time with an error value rather than a blowup. It is a re-hosting of `std.regex`'s Pike VM, not a new engine.                                                                                                                                                                                                                             | not started | [std-regex](../../research/full-text-search/std-regex.md); [engine-comparison](../../research/full-text-search/engine-comparison.md) |
| `PKC17` | In **plain** mode a query is one **literal needle, spaces included** — `foo bar` matches the substring `foo bar`, not lines containing both words. What was typed is what is searched, as `grep` and `ripgrep` define it. AND-of-terms is refused: it costs a prefilter per term plus a combination pass, and it makes the reported column ambiguous (which term is the hit?), which `PKC11`'s stored match ranges depend on being unambiguous. Users wanting disjoint terms have regex mode. | not started | [gnu-grep](../../research/full-text-search/gnu-grep.md); `PKC9`                                                                      |

### The query splits host-side, and adds no constraint kind

`ConstraintKind` is `{extension, glob, pathSegment, filePath, gitStatus}`, and
**every** arm of `evaluateConstraints` reads `candidate.path`. A content
constraint has no meaning there, so grep does not add one: the host splits the
query before it reaches the engine, applying the path constraints to the file
list and handing the fuzzy remainder to the scanner. The only library change is
additive — a `QueryStorage.fuzzySpan()` accessor so the host can see the
remainder it must scan for.

### `PKM6` stays deferred, and this is the reasoning

A trigram index cannot help where the latency is visible. A user typing `r`,
`re`, `ren` extracts **no trigram obligation** from the first keystrokes — the
index is silent exactly when the frame budget is tightest, and the unindexed
path has to exist anyway for verification and short queries. A working tree is
also the adversarial case for incremental indexing.

If it is ever added, the evidence points at a **per-file filter** (one changed
file rewrites one filter), not global postings; positional trigrams suit a
static corpus, which is what git history would be.

The trigger for reopening it is a measurement, not an opinion: whole-repo scan
latency exceeding the frame budget on a realistic tree at the size cap, with
the literal prefilter already in place.

## `sparkles:fuzzy` (`PKM`)

A new library — `libs/fuzzy` — because the matcher is a self-contained, testable,
benchmarkable engine with no dependency on hue, exactly as `sparkles:diff` is.
Its contract-level design now lives in its own spec —
[`docs/specs/fuzzy/SPEC.md`](../fuzzy/SPEC.md), milestoned in
[`PLAN.md`](../fuzzy/PLAN.md) — grounded in the
[fuzzy-matching research catalog](../../research/fuzzy-matching/index.md);
the rows below are hue's requirements on it, traced there.

| ID     | Requirement                                                                                                                                                           | Status              | Traces to                                                                                                                                                                                                           |
| ------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `PKM1` | Every shipped fuzzy entry point and built-in analyzer must be `@safe pure nothrow @nogc`; storage is caller-owned and fixed-capacity, and errors are explicit values. | full (working tree) | attributed public API + fixed workspaces                                                                                                                                                                            |
| `PKM2` | Unittests must carry those attributes explicitly and instrument allocator calls, because `@nogc` alone does not prove allocation freedom.                             | full (working tree) | attributed tests + calibrated libc-wrap/GC audit of the complete keystroke path                                                                                                                                     |
| `PKM3` | Every returned span must **borrow** from the caller's input; the library must own no string.                                                                          | full (working tree) | DIP1000-safe slice bridges                                                                                                                                                                                          |
| `PKM4` | Scoring must be **benchmarked** (`@benchmark`) from the first commit, since a picker's whole value is that it answers within a frame.                                 | full (working tree) | reused-workspace `@benchmark`                                                                                                                                                                                       |
| `PKM5` | It must ship a `docs/libs/fuzzy/` Diátaxis tree from the package scaffold onward, as `AGENTS.md` requires of a new library.                                           | full (working tree) | `docs/libs/fuzzy/`                                                                                                                                                                                                  |
| `PKM6` | A **bigram prefilter** should narrow candidates before content scoring, once the grep source's scale justifies it. Deferred, and recorded so it is not re-derived.    | researched          | [trigram-indexes](../../research/full-text-search/trigram-indexes/index.md) — a **content** index, not a path prefilter; deferral reasoned in [recommendations](../../research/full-text-search/recommendations.md) |

## Milestones

| Milestone | Scope                                                                                                                                   | Status                                                                      | Requirements                                         |
| --------- | --------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- | ---------------------------------------------------- |
| `F0`      | `sparkles:fuzzy` — analyzers, query/glob, exact matching, ranking, bounded history, and chunked search ([PLAN M0–M7](../fuzzy/PLAN.md)) | implemented and verified                                                    | `PKM1`–`PKM5`, `PKQ*`, `PKR1`–`PKR3`, library `PKR4` |
| `P0`      | Picker state/Finder/files source, generation scheduler, synchronous fallback, and visible ranking debug toggle                          | full — `<leader>ff` opens it in both hosts; `Ctrl-S` shows the breakdown    | `PIK1`–`PIK8`, `PKS1`, UI `PKR4`                     |
| `P1`      | The view, both backends, and the layouts                                                                                                | partial — mounted in both backends; preset switching pending                | `PIK3`, `PKL1`                                       |
| `P2`      | The preview pane                                                                                                                        | full — a real document pane; the live-types oracle starts after a 2 s dwell | `PKL2`                                               |
| `P3`      | Versioned bounded frecency/query-history persistence and the **recent** source                                                          | not started                                                                 | `PKR5`, `PKR6`, `PKS3`                               |
| `P4`      | The **grep** source: three modes, the definition classifier                                                                             | not started                                                                 | `PKS2`, `PKL5`, `PKL6`, `PKC1`–`PKC17`               |
| `P5`      | The remaining sources, actions, and `resume`                                                                                            | not started                                                                 | `PKS4`–`PKS10`, `PIK9`                               |
| `P6`      | Touch: tappable rows and the soft keyboard                                                                                              | not started                                                                 | `PKL4`                                               |

## Module coverage (proposed)

The rows name the intended ownership; implementation status is tracked by the
milestone tables above.

| Source (proposed)                | Requirements                               |
| -------------------------------- | ------------------------------------------ |
| `libs/fuzzy/src/sparkles/fuzzy/` | `PKM*`, `PKQ*`, `PKR1`–`PKR3`              |
| `apps/hue/src/picker.d`          | `PIK1`, `PIK2`, `PIK5`–`PIK9`              |
| `apps/hue/src/picker_host.d`     | the host glue both backends share (`PIK1`) |
| `apps/hue/src/picker_preview.d`  | the preview document pane (`PKL2`)         |
| `apps/hue/src/picker_sources.d`  | `PIK4`, `PKS*`                             |
| `apps/hue/src/picker_view.d`     | `PIK3`, `PKL1`, `PKL4`                     |
| `apps/hue/src/keymap.d`          | `PKL3` (the picker's bindings)             |
| `apps/hue/src/picker_grep.d`     | `PKC1`–`PKC13`, `PKC15`–`PKC17`            |
| `apps/hue/src/grep_classify.d`   | `PKC14` (the definition heuristic)         |

## Relationship to existing specs

| Piece                                                                 | Role                                                                                                                                                                                          |
| --------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [`sparkles:fuzzy` SPEC](../fuzzy/SPEC.md) + [PLAN](../fuzzy/PLAN.md)  | the engine's own contract-level spec and milestones (`F0`)                                                                                                                                    |
| [fuzzy-matching research](../../research/fuzzy-matching/index.md)     | the prior-art evidence base behind both specs                                                                                                                                                 |
| [lantern.md](./lantern.md) `LMP7`/`LMP8`                              | the reserved keys this opens, and the table its actions join                                                                                                                                  |
| [tree-view.md](./tree-view.md) `TVU1`                                 | the explorer this complements — browse there, find here                                                                                                                                       |
| [feature-requirements.md](./feature-requirements.md) `SRC6`           | the document set `PKS4` picks from                                                                                                                                                            |
| [diff-view.md](./diff-view.md)                                        | what `PKS6` opens, and the `NFR8` budget this shares                                                                                                                                          |
| [config.md](./config.md)                                              | where the frecency store and the picker's defaults live                                                                                                                                       |
| [`sparkles:event-horizon`](../event-horizon/benchmarks.md)            | the measured work-stealing walker the file and grep sources fan out on                                                                                                                        |
| `sparkles:build-primitives`                                           | the `.gitignore`-aware walk `PKS1` reuses                                                                                                                                                     |
| [full-text-search research](../../research/full-text-search/index.md) | the evidence base for `P4` — engines, prefilters, corpus access and the interactive contract; its [recommendations](../../research/full-text-search/recommendations.md) stage the grep source |

→ [Lantern requirements](./lantern.md) · [Tree / DAG view](./tree-view.md) · [Overview](./index.md)
