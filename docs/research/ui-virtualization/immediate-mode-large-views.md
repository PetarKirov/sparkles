# Immediate-mode large views — where rebuilding every frame stops being cheap

An adversarial measurement of how Dear ImGui, egui, Clay and `sparkles:ui`
render a 10³–10⁶-entry file tree, a long list and a big table from one frame to
the next, which retained state each of them quietly keeps to do it, and at what
size the "rebuild everything, every frame" premise breaks.

**Last reviewed:** November 24, 2026

|                     |                                                                                                                                                                                                                                  |
| ------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Question**        | Is virtualisation + a measure cache + frame skipping (option (b)) enough for [`sparkles:ui`][sparkles-ui]'s per-frame pure components, or does a large view force memoised subtree "sites"?                                      |
| **Subjects probed** | [egui][egui-pin] `0.37.0`, [Dear ImGui][imgui-pin] `1.93.1 WIP`, [Clay][clay-pin], `sparkles:ui` at `416af591d`                                                                                                                  |
| **Subjects read**   | the above, plus [VS Code's `IndexTreeModel`][vscode-pin] and the catalog's [GTK 4](./gtk4-list-factories.md), [Flutter](./flutter-slivers.md) and [cosmic-text](../font-libraries/cosmic-text.md) pages                          |
| **Builds on**       | [comparison § three separable wins](./comparison.md#three-separable-wins-not-one), [Dear ImGui](./dear-imgui-clipper.md), [egui](./egui-show-rows.md), [sparkles baseline](./sparkles-baseline.md), [tree-view case study][tvcs] |
| **Machine**         | AMD Ryzen 9 7940HX (16 cores / 32 threads, `performance` governor), 29 GiB, Linux 6.18.26; each probe pinned to one core with `taskset`                                                                                          |

## What this page adds

The catalog already establishes the shape of the answer: immediate-mode
toolkits take [win 1 and win 2](./comparison.md#three-separable-wins-not-one) —
don't build what you cannot see, don't re-derive the data — and never win 3,
view reuse, because an immediate-mode "item" is a few draw calls rather than an
object. It cites [`ImGuiListClipper`](./dear-imgui-clipper.md) and
[`show_rows`](./egui-show-rows.md) from source and measures
[hue's DSV grid](./sparkles-baseline.md). What it does not have is:

1. **Numbers for the immediate-mode toolkits themselves** — per frame, for
   everything built versus a window, against `N`.
2. **Trees.** Every subject page is about a flat list. A tree adds a
   flattening step whose cost is `O(expanded)` and a family of operations —
   scroll-to-selected, variable heights, animation, find — that each want a
   structure the frame does not rebuild.
3. **The text caches** the "rebuild everything" toolkits keep to make
   rebuilding cheap, and what happens when they miss.
4. **The maintainers' own statements** about where it stops working.

The probes below fill those gaps; the [lessons](#lessons-for-sparkles-ui)
section turns them into a verdict on option (b).

## The probes

Four headless programs, one per toolkit, each running a fixed scenario for many
frames with no window, GPU or event loop and reporting the median CPU time per
frame (first frame reported separately, as the cold-cache case).

| Probe            | Location                                      | Frame measured                                                                                 | Build                                                                        |
| ---------------- | --------------------------------------------- | ---------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------- |
| probe (egui)     | `$TMPCODE/imgui-large/egui-probe/src/main.rs` | `Context::run_ui` (begin → widgets → `end_pass`); `Context::tessellate` timed separately       | `cargo build --release` (rustc 1.99), `egui` as a path dependency on the pin |
| probe (ImGui)    | `$TMPCODE/imgui-large/imgui-probe/main.cpp`   | `NewFrame` → widgets → `Render`, null backend, `io.DisplaySize = 1280×800`                     | `g++ -O2 -g` (GCC 16.2), asserts left on                                     |
| probe (Clay)     | `$TMPCODE/imgui-large/clay-probe/main.c`      | `Clay_BeginLayout` → elements → `Clay_EndLayout`, measure callback `8 px × length`             | `gcc -O2 -g`, `clay.h` copied from the pin                                   |
| probe (sparkles) | `$TMPCODE/imgui-large/sparkles-probe/probe.d` | `Builder.reset` → `treeView` → `layout(…, LayoutStore)` → `buildDisplayListInto(…, CmdBuffer)` | `dub build --single probe.d -b checked --compiler=ldc2` (LDC 1.43)           |
| probe (extent)   | `$TMPCODE/imgui-large/extent-probe/main.cpp`  | locating the visible range over variable row heights                                           | `g++ -O2`                                                                    |

The tree is the same in every probe: node `i`'s children are
`16i + 1 … 16i + 16`, so `N = 10⁶` is a tree of depth 5 with 62 500
directories; labels are `dir_<i>` / `file_<i>.rs`. "All open" means every
directory is expanded, so the flattened tree has exactly `N` rows. The viewport
is 800 px (≈ 40 egui rows, ≈ 50 Clay rows) or 48 cells (`sparkles`). Each
probe is run as `taskset -c <core> <probe> <scenario> <N>`; the frame count is
`clamp(2·10⁶ / N, 8, 200)` (200 for virtualised scenarios in `sparkles`), and
the median excludes the first frame.

> [!WARNING]
> Read these as **per-toolkit scaling curves, not a league table.** The
> toolkits do different work per row: egui and ImGui lay out proportional text
> from a real font, Clay calls a trivial measure function, and `sparkles` lays
> out styled `rich` rows of five to eight spans on a cell grid. ImGui ran with
> assertions on; `sparkles` ran its shipping `checked` build, also with
> assertions on. Wall time on a pinned core, not instruction counts — the
> [baseline's caution](./sparkles-baseline.md#a-caution-about-reading-these-numbers)
> applies, so differences under ~10% are noise.

---

## 1. Everything built versus a window

### probe (egui) — median µs per frame

| Scenario                                            |    10³ |     10⁴ |       10⁵ |        10⁶ |
| --------------------------------------------------- | -----: | ------: | --------: | ---------: |
| `ScrollArea::show`, `N` labels (all built, clipped) |    324 |   3 432 |    63 910 |  1 038 091 |
| ↳ its first frame (cold galley cache)               | 11 241 | 107 481 | 1 073 028 | 11 572 572 |
| `show_rows`, static                                 |   19.7 |    19.4 |      19.4 |       19.8 |
| `show_rows`, scrolled one row per frame             |   27.5 |    27.2 |      27.4 |       27.2 |
| `show_rows`, scrolled one page per frame            |  15.9ᵃ |   271.5 |     279.0 |      276.9 |
| `tessellate` after `ScrollArea::show`               |     17 |      18 |        54 |         58 |

ᵃ At 10³ an 800-px page per frame reaches the end of the list within 23 frames,
so the median is mostly static frames.

### probe (ImGui) — median µs per frame

| Scenario                                            |  10³ |   10⁴ |    10⁵ |     10⁶ |
| --------------------------------------------------- | ---: | ----: | -----: | ------: |
| `N` × `TextUnformatted` (all submitted)             | 68.7 |   644 |  6 638 |  66 257 |
| ↳ its first frame                                   |  519 | 1 007 |  6 758 |  69 505 |
| `ImGuiListClipper`, static                          | 11.3 |  11.8 |   12.3 |    12.5 |
| `ImGuiListClipper`, `SetScrollY` one page per frame | 11.7 |  12.5 |   12.9 |    12.8 |
| 4-column `BeginTable`, all rows                     |  249 | 2 375 | 24 473 | 247 910 |
| 4-column `BeginTable` + clipper                     | 28.3 |  28.7 |   29.2 |    28.6 |

### probe (Clay) — median µs per frame

| Scenario                                          |  10³ |   10⁴ |     10⁵ |      10⁶ |
| ------------------------------------------------- | ---: | ----: | ------: | -------: |
| `N` × `CLAY_TEXT` in a clip container             |  205 | 2 519 | 21 045ᵇ | 262 152ᵇ |
| ↳ its first frame                                 |  552 | 6 148 |  51 258 |  568 580 |
| app-windowed (two spacer elements + visible rows) | 15.9 |  16.0 |    17.1 |     16.6 |
| app-windowed, scrolled one page per frame         | 16.1 |  24.2 |    26.5 |     26.9 |

ᵇ With `CLAY_ERROR_TYPE_DUPLICATE_ID` raised 34 464 times per frame at 10⁵ and
934 464 times per frame at 10⁶: 10⁵ auto-IDed siblings collide in Clay's 32-bit
element-ID hash ([`Clay__HashNumber`][clay-hashnum]). The probe counts the
errors and carries on; the times include the error handler.

### probe (sparkles) — median µs per frame

| Scenario                                             |    10³ |     10⁴ |       10⁵ |            10⁶ |
| ---------------------------------------------------- | -----: | ------: | --------: | -------------: |
| `treeView` over all flattened rows                   |  2 570 |  97 493 | 1 869 311 | killed by OOMᶜ |
| ↳ its first frame                                    | 19 322 | 231 077 | 2 444 846 |              — |
| `treeView` over the explorer's 49-row window, static |    114 |     124 |       243 |            248 |
| ↳ scrolled one page per frame                        |   120ᵃ |     752 |       898 |            845 |
| `N` plain `text` nodes, all built                    |    108 |   1 211 |    16 049 |        204 594 |
| 49 plain `text` nodes                                |    7.8 |     8.0 |       8.2 |            8.2 |

ᶜ `Out of memory: Killed process … anon-rss:21394792kB` — 3 × 10⁶ widgets at
328 bytes each plus their spans and frames. ᵃ At 10³ the scrolled window cycles
through rows the wrap cache already holds.

The phase split for the static 49-row window at 10⁴ is build 24 µs, layout
86 µs, display list 13 µs; scrolled a page per frame it becomes build 73 µs,
layout 651 µs, display list 13 µs. The `NFR4` budget in
[`feature-requirements.md`][nfr4] — under 1 ms for 2 000 nodes — holds for
plain text (2 002 nodes: **0.22 ms**) and fails for tree rows (2 003 nodes,
667 rows: **1.53 ms**).

### What the curves say

**Virtualisation makes every toolkit flat in `N`.** With a window, the frame is
the same at 10³ and 10⁶ in all four: 12.5 µs (ImGui), 19.8 µs (egui), 16.6 µs
(Clay), 8.2 µs (`sparkles`, plain text). The catalog's
[win 1](./comparison.md#three-separable-wins-not-one) is not a claim to
re-prove; it is confirmed to within noise.

**Without it, the per-row constant decides where the budget breaks.** Dividing
the all-built rows by `N`:

| Toolkit, row kind                  | µs per built row (warm) | Rows until 4 ms | Rows until 16.7 ms |
| ---------------------------------- | ----------------------: | --------------: | -----------------: |
| ImGui `TextUnformatted`            |                   0.066 |          ~6·10⁴ |           ~2.5·10⁵ |
| ImGui 4-cell table row             |                    0.25 |        ~1.6·10⁴ |             ~7·10⁴ |
| Clay text element                  |               0.20–0.26 |          ~2·10⁴ |             ~8·10⁴ |
| egui `Label`                       |                0.34–1.0 |        ~1.2·10⁴ |           ~2.5·10⁴ |
| `sparkles` plain `text` node       |                0.11–0.2 |          ~3·10⁴ |             ~1·10⁵ |
| `sparkles` tree row (`rich` spans) |             2.6 → 18.7ᵈ |        ~1.5·10³ |           ~2.5·10³ |

ᵈ Superlinear: 2.6 µs at 10³, 9.7 µs at 10⁴, 18.7 µs at 10⁵. See
§ 3, _Text_.

So "immediate mode is cheap" means, concretely, that **a whole view of up to
~10⁴ simple rows** can be rebuilt every frame in every toolkit probed. Past
that, every one of them needs the caller to stop submitting rows — and the
`sparkles` tree row is an order of magnitude more expensive than any other
toolkit's row, which moves its own knee down to ~10³.

---

## 2. Trees

A list virtualises by division: `first = scroll / rowHeight`. A tree has to be
**flattened** — hierarchy plus disclosure state into the sequence of visible
rows — before it can be divided, and flattening is `O(expanded)`. The question
is whether that is paid every frame or kept.

### probe (tree) — the three ways to draw an all-open tree, median µs per frame

| Strategy                                                      | Toolkit  |   10³ |   10⁴ |    10⁵ |     10⁶ |
| ------------------------------------------------------------- | -------- | ----: | ----: | -----: | ------: |
| **Nested** widgets, recursing into every open node            | egui     |   429 | 4 570 | 73 103 | 963 948 |
| — `CollapsingHeader` per directory, root collapsed            | egui     |   4.1 |   3.9 |    4.1 |     4.1 |
| **Nested**, `TreeNodeEx(DefaultOpen)`                         | ImGui    |  57.6 |   541 |  5 478 |  55 997 |
| **Seek**: zero-cache clipper, walks visible order every frame | ImGui    |  10.3 |  30.6 |    224 |   2 215 |
| **Index**: flattened rows kept by the app + `show_rows`       | egui     |  33.8 |  35.0 |   35.1 |    35.1 |
| — scrolled one page per frame                                 | egui     | 29.6ᵃ |   201 |    215 |     220 |
| **Index** + `ImGuiListClipper`                                | ImGui    |   8.2 |   8.4 |    8.9 |     8.7 |
| **Index** + window (the explorer today)                       | sparkles |   114 |   124 |    243 |     248 |

### probe (tree) — the index's price: rebuilding it on a disclosure change, µs

| Rebuild                                               | Toolkit  | 10³ | 10⁴ |   10⁵ |    10⁶ |
| ----------------------------------------------------- | -------- | --: | --: | ----: | -----: |
| DFS into `Vec<(u32, u16)>`                            | egui     |   5 |  65 |   520 |  5 540 |
| DFS into `std::vector<Row>`                           | ImGui    |   2 |  80 |   700 |  6 300 |
| `flatten` (`FlatTreeRow` with a `Guide[]` per row)    | sparkles |  75 | 732 | 7 391 | 80 669 |
| `measureContent` (widest row, for the horizontal bar) | sparkles |   5 |  59 |   668 |  9 647 |

Three results stand out.

- **Nested immediate-mode trees are lists that never virtualise.** egui's and
  ImGui's tree widgets clip only paint, so an all-open tree costs what the
  all-built list costs (egui: 0.96 s at 10⁶). Collapsing is the only
  virtualisation they get: egui's closed `CollapsingHeader` skips its body, so
  a collapsed 10⁶-node tree is 4 µs. egui additionally paints each open body's
  indent guide whether or not it is on screen ([`Ui::indent`][egui-indent]):
  62 561 shapes reach the tessellator at 10⁶ (1.24 ms) against 49 for the flat
  list.
- **The zero-cache seek clipper is `O(expanded)` per frame with a tiny
  constant.** It is the technique ImGui's own demo now ships
  ([`DrawClippedTree`][imgui-demo-seek]): for rows outside the clipper's range
  it calls only `TreeNodeGetOpen` and advances a counter. 2.2 ns per row, so
  2.2 ms per frame at 10⁶ — affordable at 60 Hz, not at 240 Hz, and it scales
  with the tree, not the viewport.
- **An index kept across frames makes the frame flat and moves the cost to the
  toggle.** In Rust or C++ the rebuild is 5–6 ms at 10⁶ expanded rows, paid
  once per expand/collapse. The `sparkles` `flatten` is **13× slower** than
  either (81 ms) because it allocates a GC array per row
  (`rails[0 .. depth].dup ~ …` in [`tree_widget.d`][tree-widget]); with
  `measureContent` and `syncFolders` the explorer's
  [`reflatten`][explorer] spends ~90 ms at 10⁶ — five dropped frames per click.

### How each tree operation gets its answer

| Operation                                  | Needs                                      | ImGui                                                                                                                                                                                              | egui                                                                                                                                                              | `sparkles` explorer                                                                         |
| ------------------------------------------ | ------------------------------------------ | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------- |
| **Total content height** (scrollbar)       | visible-row count × row height             | `Begin(INT_MAX)` + `SeekCursorForItem(count)` after walking every visible node                                                                                                                     | `set_height(row_h × total_rows)` — the app supplies `total_rows`                                                                                                  | `tv.rows.length` × row cells — the index's length                                           |
| **Variable-height rows**                   | prefix sums of heights                     | unsupported in the clipper; maintainer: clip in pixels, "caching the height of each entry + seeking" ([#6042][imgui-6042])                                                                         | `heterogeneous_rows` walks every height every frame ([`table.rs`][egui-hetero]); maintainer: "store the bounds … binary search" ([#1376][egui-1376])              | uniform by construction (`treeRowCells` on touch)                                           |
| **Keyboard nav to an off-screen row**      | the row's index, and the row submitted     | the clipper adds the nav-scoring rect and the focused item's range to its ranges ([`imgui.cpp`][imgui-clip-nav]); multi-select needs `IncludeItemByIndex` ([`imgui.h`][imgui-include])             | per-widget `Id` survives via `skip_ahead_auto_ids` ([egui page](./egui-show-rows.md#the-identity-fix))                                                            | cursor is an index into `tv.rows`; `clamp` couples it to `top` ([`tree_view.d`][tree-view]) |
| **Scroll to selected**                     | row index → y                              | index × height; for a tree, the index requires a walk or an index                                                                                                                                  | `egui_extras` `scroll_to_row` is resolved during the same walk ([`table.rs`][egui-scrollrow])                                                                     | `O(1)` from the index                                                                       |
| **Expand/collapse animation**              | the body's height before it is laid out    | none built in                                                                                                                                                                                      | `open_height` **retained** in memory; first animated frame guesses `10.0`; the whole body is built every animated frame ([`collapsing_header.rs`][egui-collapse]) | none                                                                                        |
| **Find-in-tree highlight / filtered tree** | a filtered index, ideally with match spans | maintainer: "to implement any form of non-trivial search you will want to have this index anyhow" ([#3823][imgui-3823-seek])                                                                       | app-side                                                                                                                                                          | the query **rebuilds** the tree (`buildTree`, broot's tree-as-search-result)                |
| **Range selection across collapsed nodes** | visible order between two nodes            | demo helper `TreeGetNextNodeInVisibleOrder`, with the note that a real app "is more likely to build an array mapping sequential indices to visible tree nodes" ([`imgui_demo.cpp`][imgui-demo-ms]) | app-side                                                                                                                                                          | contiguous range of `tv.rows`                                                               |

Every row of that table is answered by **one of two retained structures**: the
**flattened row index** (row → node, node → row, count) and, when heights vary,
**prefix sums over row heights**. Neither is a widget tree, and neither is
built per frame by any toolkit that scales. ImGui's maintainer states it
plainly after shipping the zero-cache alternative:

> It's always more efficient if you can linearize your tree by creating an
> index, but then you need to have an event to notify of tree changes to
> rebuild the index. It also happens that to implement any form of non-trivial
> search you will want to have this index anyhow, at which point you can
> implement something that's much faster.
>
> — [ocornut, imgui#3823][imgui-3823-seek]

### probe (extent) — locating the window over variable heights

| Strategy                                                  | 10³ | 10⁴ |  10⁵ |  10⁶ |
| --------------------------------------------------------- | --: | --: | ---: | ---: |
| per-frame linear walk to the offset + tail sum (µs/frame) | 0.6 | 6.6 | 66.4 |  668 |
| retained prefix sums: build once (µs)                     |   1 |   6 |   61 |  619 |
| ↳ binary search per frame (ns)                            | 4.4 | 6.0 |  6.2 |  7.2 |
| Fenwick tree: update one row's height (ns)                | 2.6 | 6.9 | 23.4 | 32.4 |

egui's maintainer calls the walk "still O(N) in the number of rows, but very
fast" ([#1376][egui-1376-hetero]) and at 10⁵ it is: 66 µs. The walk is not
where variable heights get expensive, though. **The heights have to be known**,
and knowing a wrapped row's height means laying out its text — 6–13 µs a row
cold in the probes below — so a variable-height list of 10⁵ rows either
measures 10⁵ rows once and retains the result, or estimates
([Gio](./gio-list.md), [GTK](./gtk4-list-factories.md)) and lets the scrollbar
drift.

---

## 3. Text — the caches that make rebuilding cheap

Rebuilding a label every frame is cheap only if laying out its text is not
redone. Each toolkit keeps a retained cache for exactly that, and each has a
different key and eviction rule.

| Toolkit    | Cache                                                            | Key                                                                                                          | Eviction                                                                                                  | Shaping?                                                                                          |
| ---------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ | --------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------- |
| Dear ImGui | **none** for layout; per-glyph advance table in the baked font   | —                                                                                                            | —                                                                                                         | no — `CalcTextSize` sums advances every frame, even for a clipped item ([`TextEx`][imgui-textex]) |
| egui       | `GalleyCache`: `LayoutJob` → `Arc<Galley>`, per viewport         | hash of the whole `LayoutJob` and `pixels_per_point` ([`galley_cache.rs`][egui-galley])                      | **anything not used in the previous pass** ([`flush_cache`][egui-flush]); long texts cached per paragraph | layout of a shaped run                                                                            |
| Clay       | measure-text cache, per word                                     | 32-bit hash of text contents + config, compared **by hash only** ([`Clay__MeasureTextCached`][clay-measure]) | an entry unseen for more than two generations, lazily ([`clay.h`][clay-evict])                            | the app's callback                                                                                |
| `sparkles` | `LineCache` (plain) and `WrapCache` (`rich`) in [`wrap.d`][wrap] | authored spans by content + width, hang, algorithm, whitespace mode                                          | two generations of 8 192 entries / 2¹⁹ spans; rows kept only for the last 8 layout widths                 | cell profile (no shaping)                                                                         |

### probe (text) — hit rates and miss costs

| Measurement                                             | egui                           | Clay                             | `sparkles` tree rows           |
| ------------------------------------------------------- | ------------------------------ | -------------------------------- | ------------------------------ |
| static window: entries after a frame / misses per frame | 40 galleys / 0                 | 0 measure calls in frames 1–2    | — / 0 (124 µs at 10⁴)          |
| window scrolled a page per frame: misses per frame      | ~40 (all new rows)             | 300 word measurements            | 49 rows (752 µs at 10⁴)        |
| **cost per missed row**                                 | **≈ 6.4 µs** ((277 − 20) / 40) | ≈ 0.2 µs with a trivial callback | **≈ 13 µs** ((752 − 124) / 49) |
| all-built first frame vs steady (10⁴)                   | 107 ms vs 3.4 ms (31×)         | 6.1 ms vs 2.5 ms                 | 231 ms vs 97 ms (2.4×)         |

Four findings follow.

1. **Steady-state hit rate is 100%, and steady state is exactly the case
   frame skipping already removes.** A frame with nothing new on screen hits
   every entry; scrolling is the case that misses. egui pays ~6.4 µs for every
   row that _enters_ the viewport, so a page per frame costs 14× the static
   frame (277 µs vs 20 µs); one row per frame costs 1.4× (27 µs). ImGui has
   no cache and no miss: its page-scroll frame equals its static frame
   (12.8 µs vs 12.5 µs) because it never shapes.
2. **egui's eviction is "used last frame", so a cache does not survive a
   scroll back.** [`flush_cache`][egui-flush] keeps only entries touched in the
   pass just finished. The rule is tuned for a UI that rebuilds the same
   widgets every frame, and its fragility is documented in the source: two
   viewports sharing one cache made each pass "look unused" to the other and
   "continuously evict one another's working sets", fixed by giving each
   viewport its own cache ([`fonts.rs`][egui-viewportkey]; the regression is
   [egui#8610][egui-8610]).
3. **Clay's cache trusts a 32-bit hash.** At 10⁵ distinct rows the probe made
   599 574 word measurements where 600 000 were due, and 5 983 146 of
   6 000 000 at 10⁶: those rows received another string's cached width. The
   lookup compares `hashEntry->id == id` and nothing else
   ([`clay.h`][clay-measure]). The same 32-bit hashing collides element IDs at
   10⁵ siblings (§ 1, footnote ᵇ).
4. **The `sparkles` wrap cache is bounded below a whole-tree working set.**
   A tree row stores two `rich` runs (label and right-aligned badge), so 10⁴
   rows want ~2·10⁴ entries against two 8 192-entry generations. The tree's
   per-row cost climbs from 2.6 µs (10³) to 9.7 µs (10⁴) to 18.7 µs (10⁵) —
   between the 2.3–5 µs warm and ~13 µs cold row costs — consistent with a
   cache that thrashes plus a GC marking a heap that grows with `N` (13
   collections, 347 ms of 1.9 s at 10⁴). _Inferred, not decomposed further._
   The bound is deliberate — the comment above `WrapCache` records a cache
   that once "held gigabytes the collector scanned on every collection" — and
   with a window the working set is ~100 entries, far inside it.

> [!IMPORTANT]
> The `sparkles` window frame is GC-bound in its tail. Its median is flat in
> `N`, but its worst frame is not: over 400 frames the maximum was **32 ms**
> (static, 10⁶), **30 ms** (scrolling, 10⁵) and **45 ms** (scrolling, 10⁶),
> against medians of 0.2–0.8 ms. The collector marks the retained
> `TreeData` and the per-row `Guide[]` arrays, so the pause scales with the
> data even though the frame does not. No other probed toolkit has this
> failure mode; none of them allocates from a traced heap per frame.

---

## 4. Where immediate mode stops being cheap

### What the maintainers say

**egui** states the limit in its README, under "CPU usage":

> Since an immediate mode GUI does a full layout each frame, the layout code
> needs to be quick. If you have a very complex GUI this can tax the CPU. In
> particular, having a very large UI in a scroll area (with very long
> scrollback) can be slow, as the content needs to be laid out each frame.
>
> If you design the GUI with this in mind and refrain from huge scroll areas
> (or only lay out the part that is in view) then the performance hit is
> generally pretty small. For most cases you can expect `egui` to take up 1-2
> ms per frame […]
>
> — [`README.md`][egui-readme-cpu]

and, two paragraphs later, the retained state it keeps anyway: "There are some
GUI state that you want the GUI library to retain, even in an immediate mode
library such as `egui`" ([`README.md`][egui-readme-ids]). On variable heights
its maintainer answers that the only way is to know the heights beforehand,
"Or you lay out your widgets once and then store the bounds of each in a
vector" and binary-search it ([egui#1376][egui-1376]). When editing long text
re-laid out the whole text per keystroke, the fix was a cache per paragraph,
with the caveat that "the runtime complexity is still O(N)"
([egui#5411][egui-5411]).

**Dear ImGui** says so in three places. The clipper's own header: "fetching/
submitting your own data incurs additional cost"
([catalog page](./dear-imgui-clipper.md)). The tables header: "auto-resizing
columns don't play well with using the clipper"
([`imgui_tables.cpp`][imgui-tables-clip]) — a column fitted to its widest cell
needs every row, which a window does not submit. And the large-tree issue,
opened in 2021 with "dynamic (scrolling, collapsing, expanding), performance is
as bad as no clipping" ([imgui#3823][imgui-3823]), where the maintainer
proposed, among other things, constraining a large level to one open sibling
or a Finder-style column-per-level layout before shipping the seek technique
in 2026 and recommending an index instead ([comment][imgui-3823-seek]). The
same thread records his warning about measuring: "comparing FPS is very
error-prone and misleading, you should always be comparing time per frame" —
and that in the reporter's 30 000-node repro, `std::to_string` cost twice as
much as all the `TreeNode` calls ([comment][imgui-3823-tostring]).

**Clay**'s README has a section titled "Retained Mode Rendering": "Clay was
originally designed for Immediate Mode rendering … This may not be possible
with your platform, renderer design or performance constraints", and suggests
mapping render-command IDs to persistent objects and diffing commands to find
dirty elements ([`README.md`][clay-retained]).

### The retained state immediate-mode libraries keep

| Kept across frames                        | egui                                 | Dear ImGui                           | Clay                     | `sparkles`                                       |
| ----------------------------------------- | ------------------------------------ | ------------------------------------ | ------------------------ | ------------------------------------------------ |
| per-widget interaction state, keyed by id | `Memory` (open, scroll, drag, focus) | `ImGuiStorage` (open/closed, scroll) | scroll containers, hover | the element store (`WGT5` `key`), state machines |
| text layout                               | `GalleyCache`                        | glyph advances only                  | per-word measure cache   | `LineCache`, `WrapCache`                         |
| last frame's geometry                     | previous-pass rects, sizing pass     | item rects, `ItemsHeight`, nav rects | element bounding boxes   | `LayoutStore` scratch                            |
| subtree heights for animation             | `open_height` per collapsing region  | —                                    | —                        | —                                                |
| **the visible-row index of a tree**       | app's (`show_rows` over app data)    | app's, or the seek walk every frame  | app's                    | `TreeViewState.rows`, rebuilt by the adapter     |

The fifth row is the one that matters for large views, and **no immediate-mode
toolkit owns it**: every one of them leaves it to the application.

### The knees, measured

| Pattern                                      | Cost grows with                         | Where it exceeds a 4 ms frame (this machine)                                               |
| -------------------------------------------- | --------------------------------------- | ------------------------------------------------------------------------------------------ |
| every row built, cache warm                  | `N` per frame                           | ~10⁴ rows (egui, Clay, ImGui tables), ~6·10⁴ (ImGui text), ~1.5·10³ (`sparkles` tree rows) |
| every row built, cache cold (first frame)    | `N` once                                | egui 1.1 s at 10⁵; `sparkles` 2.4 s at 10⁵                                                 |
| nested tree, all open                        | expanded per frame                      | same as every-row-built                                                                    |
| seek clipper (zero cache)                    | expanded per frame                      | ~2·10⁶ expanded rows (2.2 ns/row)                                                          |
| window over a retained index                 | `V` per frame                           | never, in `N`; `sparkles` tail latency is GC-bound                                         |
| rebuilding the index on a toggle             | expanded per toggle                     | ~7·10⁵ rows (Rust/C++); ~5·10⁴ (`sparkles` `flatten`)                                      |
| new rows entering the viewport (text misses) | rows entering per frame                 | egui ~600 rows/frame; `sparkles` ~300 rows/frame                                           |
| variable heights without retained bounds     | `N` per frame, plus measuring every row | the walk ~6·10⁶ rows; measuring, ~300–600 rows                                             |

---

## 5. The case for retained mode, steelmanned

The strongest form of the doubt is not "rebuilding is slow" — the window
frames above are 10–250 µs. It is that **each of the operations in
[§ 2](#how-each-tree-operation-gets-its-answer) needs a structure that outlives
the frame**, so an immediate-mode tree is a retained model with an
immediate-mode painter on top, and the toolkit has only declined to own the
hard half. That is true, and the probes support it. What a retained toolkit
does differently for the same tree view:

- **VS Code splices instead of re-flattening.** `IndexTreeModel` keeps a
  `renderNodeCount` on every node — the number of visible rows its subtree
  contributes — and on collapse or expand it walks only that subtree, fires
  one splice for its rows, and adds the difference to each ancestor's count
  ([`_setListNodeCollapseState`][vscode-collapse],
  [`_updateAncestorsRenderNodeCount`][vscode-ancestors]). A toggle is
  `O(subtree + depth)`, not `O(expanded)`; on the 10⁶ probe tree, expanding a
  16-child leaf directory touches ~21 nodes instead of re-flattening 10⁶ rows
  (6–81 ms above). The location → list-index lookup sums sibling counts — with
  a `// TODO@joao perf!` on that loop ([`getParentNodeWithListIndex`][vscode-listindex]).
  _Not measured here; the counts are from reading the code._
- **VS Code keeps prefix sums.** Its `ListView` locates rows through a
  `RangeMap` in `O(log N)` with exact variable heights
  ([VS Code page](./vscode-listview.md)) — the structure egui's maintainer
  recommends building by hand.
- **GTK 4 binds rather than builds**, and pays only for rows whose item changed
  ([GTK page](./gtk4-list-factories.md)); its `GtkTreeListModel` (from memory,
  _not verified against a pinned tree_) expands rows lazily as the list asks
  for them.
- **Flutter's slivers measure progressively** and keep built children alive
  across small scrolls ([Flutter page](./flutter-slivers.md)).
- **cosmic-text keeps shaped lines on the buffer** and shapes only the lines in
  the scroll window (`Buffer::shape_until_scroll`,
  [cosmic-text page](../font-libraries/cosmic-text.md)) — the text half of
  virtualisation, retained.

What that buys, in the units measured here: a toggle that is `O(Δ)` rather
than 5–81 ms at 10⁶; a scrollbar that is exact for variable heights without a
walk; and, for recyclers, skipping the ~6–13 µs text layout of a row that
merely moved. It does **not** buy a cheaper frame for a static viewport — the
immediate-mode window frames are already 10–250 µs — and the catalog's
[recycling hazards](./comparison.md#recycling-exists-where-constructing-a-view-is-expensive)
are its price.

The fair reading: **retained toolkits win on change propagation (`O(Δ)`
toggles and exact incremental extents), not on per-frame cost.** Those are
properties of the _model_ behind the view, and an immediate-mode view can sit
on a model that has them.

---

## Lessons for sparkles:ui

### Verdict: option (b) is sufficient for the explorer's tree — with the index made first-class

Virtualisation makes the frame independent of `N`: the explorer already builds
only its window, and that frame costs 0.11–0.25 ms at every size probed. The
measured problems are all **outside the frame**, and none of them is solved by
memoised subtree sites:

| Problem                                                    | Measured                          | Remedy                                                                                                                                       |
| ---------------------------------------------------------- | --------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `flatten` allocates a `Guide[]` per row                    | 81 ms at 10⁶ (13× Rust/C++)       | store depth + an "is last child" bit per row and derive the guides for the **visible** rows at view time                                     |
| every toggle re-flattens all expanded rows                 | `O(expanded)` per toggle          | at 10⁵ a non-allocating flatten (~0.6 ms) is enough; at 10⁶ splice the subtree, VS Code-style, with a per-node visible-row count             |
| `measureContent` scans every row for the horizontal extent | 9.6 ms at 10⁶                     | maintain the maximum incrementally, or bound it by the window and a sample, as `DSN3` pins the DSV grid's widths                             |
| GC pauses scale with the retained data                     | 30–45 ms worst frame at 10⁵–10⁶   | keep the index and the per-frame spans off the traced heap (`Buffer`, the arena), so the collector's mark set is not the tree                |
| tree rows cost 10× other toolkits' rows                    | 2.3–5 µs warm, 13 µs cold per row | a `LAY13` measure cache, sized for the window's working set, plus a cheaper rich-row path; this, not reuse, is what a scrolling frame spends |

### The retained structures a per-frame design still needs, and where they live

1. **The flattened row index** (row → node, node → row, count). It belongs
   **beside the data, in the component's view model** — where
   `TreeViewState.rows` already is — invalidated by events (disclosure, filter,
   data change), never by frames. It is not a widget subtree and has no
   layout in it.
2. **Prefix sums of row heights**, only for variable-height lists, in the same
   place, filled from the measure cache. A Fenwick tree updates one re-wrapped
   row in 32 ns at 10⁶.
3. **A text measure cache** (`LAY13`) in the layout engine, keyed on content,
   style and width, with a capacity that comfortably holds the window plus
   overscan — and no 32-bit-hash-only equality, which Clay shows corrupts
   widths at 10⁵ entries.
4. **Per-element interaction state** keyed by data identity (`WGT5`'s `key`),
   which every immediate-mode toolkit keeps and which `skip_ahead_auto_ids`
   exists to protect.

A `lazyChildren` node is then a row count, a row height (or a prefix-sum
index), and a callback that builds rows `[first, last)` — `show_rows` in
`sparkles` vocabulary. It needs **no** retained widgets.

### What would justify memoised subtree sites

None of the probes found a case, but these would:

- **A visible region that cannot be windowed into rows** and is expensive to
  lay out — a long document of wrapped, variable-height blocks where even the
  window's layout misses its budget after `LAY13` is in place.
- **A window frame over budget on the target device after the fixes above.**
  The 0.11–0.25 ms window on a desktop core is ~10× that on a low-end Android
  core (_an estimate, not measured_); if the scrolling frame (0.75–0.9 ms here)
  then misses a 120 Hz budget, the cost is text layout of entering rows, which a
  site would only help if it kept already-laid-out rows across scrolls — that
  is, recycling, with the [hazards](./comparison.md#recycling-exists-where-constructing-a-view-is-expensive)
  the catalog documents.
- **Continuous animation in one region while a large static region repaints**,
  so frame skipping cannot apply; there a site would let the static region's
  ops be replayed. Measure the static region's share first.

Until one of those is measured, sites would buy reuse of work the window frame
does not spend.

### Doubts and gaps

- The cross-toolkit per-row constants mix different text work (see the
  warning at the top); only each toolkit's own curve is a fair comparison.
- Gio was cloned (`9816a101b3010936a1a250426703aa56bb9444e6`) but not probed;
  GTK and Flutter were not probed — their columns come from the catalog's
  source reading, and GTK's `GtkTreeListModel` behaviour is from memory.
- The `sparkles` tree-row superlinearity is attributed to wrap-cache thrash
  plus GC marking by inference; the cache exposes no hit counters.
- `Widget` measured **328 bytes**, not the 256 bytes the design assumes.
- No retained toolkit's toggle or scroll was timed; § 5's `O(Δ)` claims are
  from code reading.

## Sources

- egui at [`90431d9`][egui-pin]: [`README.md`][egui-readme-cpu],
  [`scroll_area.rs`][egui-show-rows], [`galley_cache.rs`][egui-galley],
  [`fonts.rs`][egui-viewportkey], [`collapsing_header.rs`][egui-collapse],
  [`ui.rs`][egui-indent], [`egui_extras/src/table.rs`][egui-hetero];
  issues [#1376][egui-1376], [#5411][egui-5411], [#8610][egui-8610]
- Dear ImGui at [`bd4e3b0`][imgui-pin]: [`imgui.h`][imgui-include],
  [`imgui.cpp`][imgui-clip-nav], [`imgui_widgets.cpp`][imgui-textex],
  [`imgui_tables.cpp`][imgui-tables-clip], [`imgui_demo.cpp`][imgui-demo-seek];
  issues [#3823][imgui-3823], [#6042][imgui-6042]
- Clay at [`e6cc369`][clay-pin]: [`clay.h`][clay-measure],
  [`README.md`][clay-retained]
- VS Code at [`474a349`][vscode-pin]: [`indexTreeModel.ts`][vscode-collapse]
- sparkles: [`tree_widget.d`][tree-widget], [`tree_view.d`][tree-view],
  [`explorer.d`][explorer], [`member_tree.d`][member-tree],
  [`layout.d`][layout], [`wrap.d`][wrap], [`widget.d`][widget];
  [`layout.md` (`LAY13`)][lay13], [`feature-requirements.md` (`NFR4`)][nfr4]
- Probes: `$TMPCODE/imgui-large/{egui-probe,imgui-probe,clay-probe,sparkles-probe,extent-probe}`,
  each with a `results.tsv` of the runs quoted here

<!-- References -->

[sparkles-ui]: ../../libs/ui/index.md
[tvcs]: ../tui-libraries/tree-view-case-study.md
[tree-widget]: ../../../libs/ui/src/sparkles/ui/components/tree_widget.d
[tree-view]: ../../../libs/ui/src/sparkles/ui/components/tree_view.d
[explorer]: ../../../apps/fileset-explorer/src/explorer.d
[member-tree]: ../../../apps/fileset-explorer/src/member_tree.d
[layout]: ../../../libs/ui/src/sparkles/ui/layout.d
[wrap]: ../../../libs/ui/src/sparkles/ui/wrap.d
[widget]: ../../../libs/ui/src/sparkles/ui/widget.d
[lay13]: ../../specs/ui/layout.md
[nfr4]: ../../specs/ui/feature-requirements.md
[egui-pin]: https://github.com/emilk/egui/tree/90431d979ab1faae2de6d9f736e9d33ca0d31956
[egui-readme-cpu]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/README.md#L231-L234
[egui-readme-ids]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/README.md#L240
[egui-show-rows]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/egui/src/containers/scroll_area.rs#L1087-L1118
[egui-galley]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/epaint/src/text/galley_cache.rs#L23-L31
[egui-flush]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/epaint/src/text/galley_cache.rs#L250-L256
[egui-viewportkey]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/epaint/src/text/fonts.rs#L27-L34
[egui-collapse]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/egui/src/containers/collapsing_header.rs#L186-L220
[egui-indent]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/egui/src/ui.rs#L2508-L2522
[egui-hetero]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/egui_extras/src/table.rs#L1084-L1090
[egui-scrollrow]: https://github.com/emilk/egui/blob/90431d979ab1faae2de6d9f736e9d33ca0d31956/crates/egui_extras/src/table.rs#L349
[egui-1376]: https://github.com/emilk/egui/issues/1376#issuecomment-1073001187
[egui-1376-hetero]: https://github.com/emilk/egui/issues/1376#issuecomment-1221262693
[egui-5411]: https://github.com/emilk/egui/pull/5411
[egui-8610]: https://github.com/emilk/egui/issues/8610
[imgui-pin]: https://github.com/ocornut/imgui/tree/bd4e3b0abccd653490d68beeb72f0750cde6d5f6
[imgui-include]: https://github.com/ocornut/imgui/blob/bd4e3b0abccd653490d68beeb72f0750cde6d5f6/imgui.h#L2955-L2966
[imgui-clip-nav]: https://github.com/ocornut/imgui/blob/bd4e3b0abccd653490d68beeb72f0750cde6d5f6/imgui.cpp#L3595-L3610
[imgui-textex]: https://github.com/ocornut/imgui/blob/bd4e3b0abccd653490d68beeb72f0750cde6d5f6/imgui_widgets.cpp#L183-L192
[imgui-tables-clip]: https://github.com/ocornut/imgui/blob/bd4e3b0abccd653490d68beeb72f0750cde6d5f6/imgui_tables.cpp#L158-L164
[imgui-demo-seek]: https://github.com/ocornut/imgui/blob/bd4e3b0abccd653490d68beeb72f0750cde6d5f6/imgui_demo.cpp#L9958-L9985
[imgui-demo-ms]: https://github.com/ocornut/imgui/blob/bd4e3b0abccd653490d68beeb72f0750cde6d5f6/imgui_demo.cpp#L3270-L3281
[imgui-3823]: https://github.com/ocornut/imgui/issues/3823
[imgui-3823-tostring]: https://github.com/ocornut/imgui/issues/3823#issuecomment-2245262140
[imgui-3823-seek]: https://github.com/ocornut/imgui/issues/3823#issuecomment-2257025474
[imgui-6042]: https://github.com/ocornut/imgui/issues/6042#issuecomment-1370783145
[clay-pin]: https://github.com/nicbarker/clay/tree/e6cc36941ab2af5d81107617039d6f527a1c660b
[clay-measure]: https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/clay.h#L1639-L1662
[clay-evict]: https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/clay.h#L1663-L1664
[clay-hashnum]: https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/clay.h#L1424-L1434
[clay-retained]: https://github.com/nicbarker/clay/blob/e6cc36941ab2af5d81107617039d6f527a1c660b/README.md#L522-L530
[vscode-pin]: https://github.com/microsoft/vscode/tree/474a349ad5b745e512ef86b864d1c74f7264dd7a
[vscode-collapse]: https://github.com/microsoft/vscode/blob/474a349ad5b745e512ef86b864d1c74f7264dd7a/src/vs/base/browser/ui/tree/indexTreeModel.ts#L415-L428
[vscode-ancestors]: https://github.com/microsoft/vscode/blob/474a349ad5b745e512ef86b864d1c74f7264dd7a/src/vs/base/browser/ui/tree/indexTreeModel.ts#L645-L655
[vscode-listindex]: https://github.com/microsoft/vscode/blob/474a349ad5b745e512ef86b864d1c74f7264dd7a/src/vs/base/browser/ui/tree/indexTreeModel.ts#L720-L740
