# Helix × nucleo — the consumer contract

How a production editor drives [nucleo]: injection, ticking, incremental
reparse, dynamic queries, and the derived UX signals. Surveyed because the
_contract_ — not the matcher — is what a picker host must get right, and
Helix is the reference consumer written by nucleo's own authors.

|                   |                                                                          |
| ----------------- | ------------------------------------------------------------------------ |
| Language          | Rust                                                                     |
| License           | MPL-2.0                                                                  |
| Repository        | [helix-editor/helix][helix-repo]                                         |
| Surveyed revision | [`14d6bc0f`][helix-picker] (all file/line citations pin this commit)     |
| Category          | Editor picker host (consumer of `nucleo` 0.5.0 / `nucleo-matcher` 0.3.1) |
| Algorithm class   | n/a — delegates all matching to [nucleo]                                 |

## Overview

### What it solves

Helix owns none of the matching; every picker (files, buffers, symbols,
global search) is one `Picker` type over `Nucleo<T>`. The value to this
survey is the seam: what an application must provide (items, columns, a
redraw callback, a tick point, a version counter) and what it gets back
(snapshots, match counts, running state).

### Design philosophy

Poll, don't block. The first line of `render_picker`
([`picker.rs:684`][helix-picker]) is the whole doctrine:

```rust
let status = self.matcher.tick(10);
```

— one 10 ms budget per frame, and everything else (cursor clamping, redraw,
running indicators) derives from the returned `Status`. Construction wires
the reverse direction: `Nucleo::new(Config::DEFAULT,
Arc::new(helix_event::request_redraw), None, matcher_columns)` — the worker
notifies the editor, the editor polls the worker.

## How it works — the six contract points

1. **Injection with baked-in cancellation.** Helix wraps `nucleo::Injector`
   in its own `Injector<T, D>` carrying a `version: usize` snapshot plus the
   picker's `Arc<AtomicUsize>`; `push` compares the two and returns
   `Err(InjectorShutdown)` when they diverge
   ([`picker.rs:145-184`][helix-picker]). That is the _entire_ cancellation
   protocol: producers discover they are stale on their next push and unwind
   themselves — nobody is interrupted mid-item. The injector is `Clone`, so
   a `build_parallel()` directory walk hands one clone per worker thread. A
   ZST `RequestRedrawOnDrop` field makes the last producer's drop clear the
   "running" indicator automatically.
2. **Fast start without a thread.** The file picker pushes synchronously for
   30 ms and only spawns a background thread if it has not finished by then
   ([`ui/mod.rs:292-312`][helix-ui]) — small repos never pay for a thread.
3. **Frame-rate decoupling.** `request_redraw` notifications coalesce into
   one redraw per ~33 ms (30 FPS) in the editor loop
   ([`editor.rs:2490-2503`][helix-editor]), with a `RENDER_LOCK` so an async
   task can hold the next frame until its result is in it. Matching is
   budgeted at 10 ms; rendering at 33 ms; the two never couple.
4. **Snapshot + windowed realization.** The UI reads an immutable
   `snapshot()`, takes only `matched_items(offset..end)` for visible rows,
   and computes match _positions_ lazily per visible row by re-running that
   column's pattern through a shared matcher
   ([`picker.rs:754-779`][helix-picker]). **Highlight positions are never
   stored on items** — the same conclusion [snacks-picker] reached
   independently.
5. **Incremental rematch across keystrokes.** `handle_prompt_change` diffs
   the parsed query per column, skips unchanged columns ("Fastlane: most
   columns will remain unchanged after each edit"), and passes
   `is_append = pattern.starts_with(old_pattern)` into `reparse`
   ([`picker.rs:534-581`][helix-picker]) — the flag that activates
   [nucleo]'s `Update` path (rescore survivors only, never revisit rejects).
6. **Dynamic queries are debounced state machines.** `DynamicQueryHandler`
   is an `AsyncHook` with a 100 ms default debounce (275 ms for global
   search); paste bypasses the debounce; reverting to the last-requested
   query cancels the pending run. On fire: bump `version` (invalidating
   every outstanding injector), `matcher.restart(false)`, mint a fresh
   injector, spawn the producer ([`handlers.rs:134-187`][helix-handlers]).

Column-based matching rounds out the contract: `Column::new` (filtered +
shown), `Column::hidden` (matched, never rendered — global search uses this
so regex-matched line bodies aren't fuzzy-filtered twice), `without_filtering`
(rendered, not matched); the query language routes text to columns with
`%name`, prefix-matched to the shortest matching column name.

## Analysis spine (host-side)

- **Algorithm & scoring model / Prefiltering / Memory / SIMD / Unicode** —
  delegated to [nucleo] wholesale; Helix's only algorithmic contribution is
  resetting matcher config per frame (`set_match_paths()` applied only for
  file-preview pickers).
- **Incremental & streaming architecture** — the six points above; plus the
  derived UX signal worth copying: the header is
  `"{running}{matched}/{total}"` where
  `running = status.running || matcher.active_injectors() > 0` — two
  _independent_ sources (matcher busy, producers alive), either alone
  under-reports. Preview highlighting is separately debounced at 150 ms and
  skipped when the path is unchanged; on close, a picker holding over
  1,000,000 items is dropped rather than cached.

## Strengths

- The cleanest producer/matcher/UI seam surveyed: `Injector` (+ version) in,
  `tick(10) → Status` out, immutable snapshots between.
- Cancellation via a monotonic counter checked _by the worker at the seam_ —
  matcher state needs no locks on the fast path.
- The 30 ms synchronous-start heuristic.
- Append detection at the host level, activating the matcher's incremental
  path.

## Weaknesses

- Positions recomputed through a global matcher mutex per visible row per
  frame — fine at visible-window scale, but a lock in the render path.
- The debounce constants (100/150/275 ms) are scattered per call site rather
  than centralized.
- `prefer_prefix`-style ranking tweaks must round-trip through nucleo's
  `Config` — the host cannot re-rank locally (contrast [fff]'s re-ranking
  layer).

## Key design decisions and trade-offs

| Decision                                  | Rationale                                           | Trade-off                                             |
| ----------------------------------------- | --------------------------------------------------- | ----------------------------------------------------- |
| Poll (`tick`) instead of worker-pushes-UI | Frame loop stays owner of timing; no re-entrancy    | Results can sit ready up to one frame                 |
| Version counter checked in `push`         | Lock-free cancellation; producers self-terminate    | Stale producers run until their next push             |
| Positions derived per visible row         | No per-item storage; always consistent with pattern | Re-runs the pattern per row per frame (mutex-guarded) |
| 30 ms sync start, then thread             | Small corpora never pay thread startup              | A 31 ms corpus pays both                              |
| Hidden/filter-less columns                | One matcher serves regex + fuzzy hybrid pickers     | Column routing complexity in the query language       |

## Sources

- [`helix-term/src/ui/picker.rs`][helix-picker] — construction, injector,
  tick, snapshot, prompt-change fastlane, running indicator.
- [`helix-term/src/ui/picker/handlers.rs`][helix-handlers] — dynamic-query
  debouncing and the version/restart/re-inject reset.
- [`helix-term/src/ui/mod.rs`][helix-ui] — the 30 ms synchronous start.
- [`helix-view/src/editor.rs`][helix-editor] — 33 ms redraw coalescing.
- [`helix-core/src/fuzzy.rs`][helix-fuzzy] — the shared global matcher.

<!-- References -->

[helix-repo]: https://github.com/helix-editor/helix
[helix-picker]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/picker.rs
[helix-handlers]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/picker/handlers.rs
[helix-ui]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-term/src/ui/mod.rs
[helix-editor]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-view/src/editor.rs
[helix-fuzzy]: https://github.com/helix-editor/helix/blob/14d6bc0febed9c692048271a8ae2362ac969c6e0/helix-core/src/fuzzy.rs
[nucleo]: ./nucleo.md
[snacks-picker]: ./snacks-picker.md
[fff]: ./fff.md
