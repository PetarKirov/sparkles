# Sparkles baseline — where the DSV grid stands

The system this survey exists to improve: `hue`'s DSV data browser, rendering a
delimiter-separated file as a scrollable grid through
[`sparkles:ui`](../../libs/ui/index.md). This page states what is already
virtualized, what is not, and — from a phase-decomposition benchmark — exactly
what a scroll notch costs today.

**Last reviewed:** August 30, 2026

|                         |                                                                                    |
| ----------------------- | ---------------------------------------------------------------------------------- |
| **Toolkit**             | [`sparkles:ui`](../../libs/ui/index.md) — canvas-first, flat widget arena          |
| **Rendering model**     | Immediate: `view → layout → buildDisplayList → paint`, rebuilt per change          |
| **Virtualization unit** | Data row, via `DsvWindow` (`DSN4`)                                                 |
| **Spec**                | [`docs/specs/hue/dsv-preview.md`](../../specs/hue/dsv-preview.md) — `DSN3`, `DSN4` |
| **Benchmark**           | `apps/hue/src/dsv_bench.d` (`dub test :hue -- --bench -i dsv.bench`)               |

## The pipeline

A DSV document reaches the screen through six stages, and the interesting fact
is that only the last three are bounded by the viewport:

```
file bytes
  │  sniff          detect the dialect over a ≤256 KiB sample   O(bytes)
  │  parseDsv       records + cells, spans into the source      O(bytes)
  │  inferColumnTypes / detectHeader                            O(100 records)
  │  applyProjection  filter + sort → a permutation             O(rows), O(r log r) sorted
  ▼
DsvDoc + row permutation
  │  buildTable     synthesize the md table for ONE WINDOW      O(window)   ← DSN4
  ▼
MdDoc
  │  previewOf      the md preview model                        O(window)
  │  viewMarkdownInto → WidgetTree                              O(window)
  │  layout → buildDisplayList → paint                          O(window)
  ▼
canvas
```

`adaptDsv` runs the whole of the top half on **every window change**
(`apps/hue/src/dsv_view.d`), and `Workspace.applyDsvBrowser` calls it from the
scroll hook (`apps/hue/src/workspace.d`).

## What is already virtualized

### The window (`DSN4`)

`adaptDsv` takes a `DsvWindow` and materializes only that slice of the projected
order:

```d
struct DsvWindow
{
    uint start;
    uint rows;

    /// `true` when this asks for everything (the default).
    bool whole() const @safe pure nothrow @nogc => rows == 0;
}
```

— [`apps/hue/src/dsv_view.d`](../../../apps/hue/src/dsv_view.d)

`rows == 0` means "the whole view", which is what every non-scrolling sink uses
— `--html`, the pager, the goldens, copy. The window is the same
[realized window](./concepts.md#realized-window) as
[Slint's `offset` + instances](./slint-repeater.md), expressed as a request
rather than as retained state: sparkles rebuilds, so the window is an _input_ to
the build, not a description of what is currently built.

The window is sized as the pane's line count **plus eight rows of slack**
(`Workspace.dsvWindowRows`) — the [overscan band](./concepts.md#overscan--cache-extent),
the same idea as Flutter's 250-pixel [`cacheExtent`](./flutter-slivers.md) and
WPF's [`CacheLength`](./avalonia-wpf-virtualizing-panels.md), in units of items.

### The virtual extent

A windowed table's scrollbar must describe the _whole_ view, not the ~50 rows
that exist. `TableViewportSpec` carries the two numbers that make that so:

```d
size_t virtualLines;
size_t virtualOffset; /// ditto — the window's first line in that space
```

— [`libs/ui/src/sparkles/ui/components/table/widgets.d`](../../../libs/ui/src/sparkles/ui/components/table/widgets.d)

and the bar prefers them over the built content when present:

```d
const barContent = vp.virtualLines > 0
    ? cast(int) vp.virtualLines : contentLines;
const barOffset = vp.virtualLines > 0
    ? cast(int) vp.virtualOffset : sy;
```

This is the **declared** extent strategy of
[concepts § virtual extent](./concepts.md#virtual-extent) — exact, no
measurement — available because a DSV grid row is one line. It is the same
choice [egui's `set_height`](./egui-show-rows.md) and
[Slint's `cached_item_height`](./slint-repeater.md) make.

### Pinned geometry (`DSN3`)

Column widths are measured **once over a bounded sample in source order** and
pinned through `MdTableExtras.columnWidths` onto the table's minimum _and_
maximum widths. Sampling the projected order would make the widths a function of
the sort and the filter; measuring every row would restore the whole-file scan
that `DSN4` exists to remove. This is the sparkles answer to the problem
[Gio](./gio-list.md) and [Avalonia](./avalonia-wpf-virtualizing-panels.md) solve
with estimation: rather than estimate a size that may later prove wrong, fix it
from a sample and clip anything that exceeds it.

### The identity offset — already bitten once

Because the built document contains only the window, a view row's index is not a
data row's index. `DsvCopy.rawCell` has to say so explicitly:

```d
const dataRow = viewRow - 1 + info.windowStart;
```

— [`apps/hue/src/dsv_view.d`](../../../apps/hue/src/dsv_view.d)

That is exactly the hazard [egui fixes with
`skip_ahead_auto_ids`](./egui-show-rows.md) and Avalonia with its out-of-window
`_focusedElement`: **anything keyed by position in the built output shifts when
the window moves.** In sparkles it surfaced as copy taking the wrong cell, and
`MdTableExtras.virtualRowOffset` exists to carry the same correction into the
view. Every future feature that maps a screen position back to a record — cell
selection, the fuzzy-match highlight, a per-row annotation — must pass through
the same offset.

> [!WARNING]
> The related trap already cost a rewrite: passing the host's scroll offset to an
> **already-windowed** table double-scrolls it. `markdown.d` therefore forces
> `y: opt.tableExtras.virtualRows > 0 ? 0 : ts.y` — the window _is_ the scroll.

## What was not virtualized — the measurement

`apps/hue/src/dsv_bench.d` decomposes one scroll notch. Corpus: a
`files.csv`-shaped table, 3012 rows × 8 columns (~200 KiB), window 48 rows.
LDC 1.42, run as

```bash
dub test :hue -b bench -- --bench -i dsv.bench \
    --perf --metrics=instr --perf-iters=8 --bench-min-time 200
```

Both knobs matter. `-b bench` is the optimized, assertions-off build the runner
demands (it warns outright that assert-enabled numbers are meaningless).
`--perf-iters` pins the counting pass and `--bench-min-time 200` widens the
wall-clock budget, without which the auto-scaler gives different legs different
batch sizes and the medians wander by hundreds of microseconds — see the
[caution below](#a-caution-about-reading-these-numbers).

**Instructions per iteration are the number to compare.** They are
architectural: immune to frequency scaling, to how the auto-scaler batched the
leg, and to whatever else the machine was doing.

| Phase                                               | Scope                |     Median |  instr/iter | Bounded by the window? |
| --------------------------------------------------- | -------------------- | ---------: | ----------: | ---------------------- |
| **`sniff`**                                         | 256 KiB sample       | **1.9 ms** |  **44.58M** | ✗                      |
| `parseDsv`                                          | whole file           |     291 µs |       7.12M | ✗                      |
| `applyProjection`, no sort                          | whole file           |      10 µs |       248 k | ✗                      |
| `applyProjection`, **one sort key**                 | whole file           | **5.2 ms** | **134.29M** | ✗                      |
| `detectHeader`                                      | bounded              |       8 µs |       168 k | n/a                    |
| `inferColumnTypes`                                  | 100 records          |       7 µs |       167 k | n/a                    |
| `adaptDsv` **with** a 48-row window                 | model + build        |     2.3 ms |      53.42M | partly                 |
| `adaptDsv` with no window (pre-`DSN4`)              | model + build        |     7.5 ms |      91.74M | ✗                      |
| `adaptDsv`, windowed, over a 100-row file           | model + build        |     167 µs |       2.96M | —                      |
| `previewOf`                                         | window               |     930 ns |      21.7 k | ✓                      |
| `remateralizeWindow` (view + layout + display list) | window               | **2.8 ms** |  **26.62M** | ✓                      |
| **one scroll notch, total**                         | model + build + view | **5.0 ms** |      79.14M |                        |
| **one scroll notch, with a sort engaged**           | model + build + view |  **10 ms** |     214.47M |                        |

Three findings followed, and they reordered the work:

1. **The sniffer was the largest single item in the model half — and pure
   waste.** `adaptDsv` re-sniffed the dialect on every call even though the
   caller had already resolved it and was passing it straight back in as flags,
   whereupon the sniff's verdict was overridden. `sniffMaxBytes` is 256 KiB, so
   for any file up to that size the "bounded sample" is the whole file.

2. **The view half is the smaller half.** Building the widget tree, laying it
   out and producing the display list for a 48-row window costs 2.8 ms.
   Retaining that tree and mutating cells (the
   [VS Code range-diff](./vscode-listview.md) or
   [GTK bind](./gtk4-list-factories.md) approach) could attack only that, and
   only the genuinely redundant part of it.

3. **Under an active sort the model half dominated everything.**
   `applyProjection` with one sort key costs 5.2 ms / 134M instructions — more
   than the entire unsorted notch — because the comparator decodes cells on
   every comparison. A sorted view re-sorted the whole file on every notch,
   recomputing an identical permutation each time.

The two `adapt-window` rows bracket the waste directly: the same 48-row window
cost **167 µs** over a 100-row file and **2.4 ms** over a 3012-row file. Since
the _build_ is identical, the difference was entirely unbounded model work.

### What changed: `DSN7`, the retained model

The catalog's [win 2](./comparison.md#the-consensus) — _don't re-derive data you
already had_ — is now implemented. `DsvModel` (`apps/hue/src/dsv_view.d`) holds
the resolved dialect, the parse, the sampled column types and the header names,
and memoizes both the row permutation and the fuzzy filter mask.
`adaptDsv(model, proj, window)`, `DsvCopy.of(model, …)` and
`fuzzyRowMask(model, …)` all take it — which also removed the **second and third
whole-file parses** a notch used to pay, one inside `DsvCopy` and one inside the
filter. `modelFor` is the reuse test, comparing the source by slice **identity**
so a reload re-resolves.

| Scroll notch, 3012 rows | model re-derived |      model retained |    Δ |
| ----------------------- | ---------------: | ------------------: | ---: |
| unsorted                |  5.0 ms / 79.14M | **2.7 ms / 26.94M** | 1.9× |
| **with a sort engaged** |  10 ms / 214.47M | **2.8 ms / 26.98M** | 3.6× |

The two retained rows are the result worth having, and the instruction counts
are what make it a claim rather than an impression: **26.94M against 26.98M —
0.15% apart.** A scroll over a sorted view and a scroll over an unsorted one now
execute the same work, because the sort does not participate in scrolling at
all. Sorting still costs its full 5.2 ms — once, when the user actually sorts.

The retained notch is also, almost exactly, the `remateralizeWindow` row above
(26.94M vs 26.62M): with the model retained, **the windowed build costs about
0.3M instructions and everything else in a notch is the view rebuild.**

End to end through a real pty (`apps/hue/tools/tui-scroll-bench.d` over the
3012-row `apps/hue/samples/dsv/files.csv`, which times how long the tty stays
busy after a keystroke), one Down key went from a **6.2 ms** median to
**3.3 ms** over 60 keystrokes — the same 1.9× the benchmark reports, with
byte-identical frames, so it is the same output produced in half the time.
First paint is unchanged (28–30 ms either way, over three runs each), as it
must be: the first window still has to resolve the model.

What remains is the view half, and it is now essentially the whole notch. That
is the moment the catalog says to reconsider
[win 3](./comparison.md#on-win-3-specifically) — with a number rather than an
intuition.

### A caution about reading these numbers

An earlier pass at this table reported the sorted retained notch as **2.2 ms**,
_faster_ than the unsorted **2.8 ms**, and the write-up went looking for a
reason a sorted window might be cheaper to build. There is none. The two legs
had been auto-scaled differently — one measured batches of two iterations, the
other single iterations — and at ±480 µs of run-to-run spread the medians
simply crossed. Pinning the counting pass (`--perf-iters=8`) and widening the
budget (`--bench-min-time 200`) collapsed the spread to ±36 µs and put both legs
on the same 2.8 ms, which the instruction counts then confirmed to 0.15%.

Two rules follow, and they generalize past this table:

- **Compare instructions, not wall time**, whenever the question is "does this
  do less work?". `instr/iter` is architectural; it does not care about CPU
  frequency, batch size, or the rest of the machine.
- **A difference you cannot explain is usually not real.** The tell was that no
  mechanism could account for it: with the model retained, the sorted and
  unsorted paths run the same code over the same window. That should have
  prompted a re-measure, not a search for an explanation.

> [!NOTE]
> Writing this benchmark surfaced a trap worth recording: `benchIter` does not
> run its body, it _registers_ it, and the runner executes it after the enclosing
> `unittest` has returned. A fixture that lives in that frame is therefore already
> destructed by the time it is timed — a `DsvDoc`'s `Buffer` members release
> their storage and zero their lengths, so the document reads back **empty** and
> the leg silently measures nothing. Plain scalars survive (freed stack memory
> keeps its bytes), which is what makes it look like a data bug rather than a
> lifetime one. Every fixture here is a `class` so the GC keeps it alive, and the
> legs assert their row counts.

## Analysis against the spine

### 1. What the window bounds

**Build, layout, paint — and, since `DSN7`, data access too.** The model is
resolved once per document and indexed per window, which puts sparkles with the
[builder/model](./concepts.md#model-protocol) family rather than with
[Ratatui](./ratatui-offsets.md), whose bounded view still sits on a
fully-materialized item vector.

The data laziness is one level coarser than
[GTK's `GListModel`](./gtk4-list-factories.md) or
[Slint's `Model`](./slint-repeater.md), which can be lazy per row: sparkles
parses the whole file once, eagerly, and then indexes it. That is the right
trade at the sizes the spec targets today, and `DSN2`'s background record index
is where per-row laziness would land.

### 2. How the range is computed

Division: the grid's row height is one line, so `windowStart` comes straight from
the table's scroll offset. Exact, `O(1)`, and legitimate — the uniformity
assumption that [egui](./egui-show-rows.md) makes is _true_ here rather than
assumed.

### 3. What survives between frames

The `DsvModel` — the parse, the column types, the header names, the memoized
row permutation and the memoized filter mask — plus the scroll offset and the
interaction machines that `remateralizeWindow` deliberately preserves (`barSv`,
`tableScrollAt`, folds). **Not** the widget tree: sparkles remains immediate
mode, in company with [Dear ImGui](./dear-imgui-clipper.md),
[egui](./egui-show-rows.md) and [Gio](./gio-list.md), none of which retains
per-item views either.

### 4. How the extent is known

Declared and exact, via `virtualLines` / `virtualOffset`.

### 5. What breaks

- The window offset must be applied everywhere a view coordinate becomes a data
  coordinate — already fixed for copy, and a standing obligation for every new
  feature.
- **Model staleness.** A retained model is a cache, and `modelFor`'s identity
  test is what keeps it honest: the source is compared by slice identity, so a
  reload of the same bytes re-resolves rather than silently reusing a model
  built over a buffer the document no longer owns.
- **Memo depth.** The projection memo holds exactly one entry, so alternating
  between two sorts recomputes each time. That is deliberate — the entry is
  keyed by a copy of the spec, and a multi-entry cache would need an eviction
  policy for a case no interaction produces.
- Scroll latency is now dominated by the view rebuild, which is where
  [win 3](./comparison.md#on-win-3-specifically) would apply if it ever needs
  to.

## The delta

| Capability                              | Prior art                                                                                                                                                     | Sparkles today                                                                 |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| Bounded build                           | universal                                                                                                                                                     | ✓ `DsvWindow` (`DSN4`)                                                         |
| Exact virtual extent                    | [egui](./egui-show-rows.md), [Slint](./slint-repeater.md), [VS Code](./vscode-listview.md)                                                                    | ✓ `virtualLines` / `virtualOffset`                                             |
| Overscan band                           | [Flutter](./flutter-slivers.md), [WPF](./avalonia-wpf-virtualizing-panels.md), [Qt Quick](./qt-quick-listview.md)                                             | ✓ `+8` rows                                                                    |
| Stable geometry across scroll           | rare — most estimate                                                                                                                                          | ✓ `DSN3` pinned widths (stronger than the field)                               |
| Window-offset identity correction       | [egui](./egui-show-rows.md), [Flutter](./flutter-slivers.md)                                                                                                  | ✓ `windowStart` / `virtualRowOffset`                                           |
| **Persistent model, queried per index** | [Qt](./qt-quick-listview.md), [GTK](./gtk4-list-factories.md), [Flutter](./flutter-slivers.md), [Slint](./slint-repeater.md), [VS Code](./vscode-listview.md) | ✓ `DsvModel` (`DSN7`); whole-file eager parse, not per-row lazy                |
| **Cached projection (sort/filter)**     | implied by every model protocol                                                                                                                               | ✓ memoized on the model, one entry                                             |
| View reuse across scroll (recycling)    | [GTK](./gtk4-list-factories.md), [Qt](./qt-quick-listview.md), [WPF](./avalonia-wpf-virtualizing-panels.md), [VS Code](./vscode-listview.md)                  | ✗ — deliberately; see [`comparison.md`](./comparison.md#on-win-3-specifically) |

## Sources

- [`apps/hue/src/dsv_view.d`](../../../apps/hue/src/dsv_view.d) — `DsvModel`, `modelFor`, `adaptDsv`, `DsvWindow`, `sampledColumnWidths`, `DsvCopy`
- [`apps/hue/src/workspace.d`](../../../apps/hue/src/workspace.d) — `applyDsvBrowser`, `dsvWindowRows`, `dsvGridTop`
- [`apps/hue/src/viewer_model.d`](../../../apps/hue/src/viewer_model.d) — `remateralizeWindow`, `rebuildTree`
- [`apps/hue/src/dsv_bench.d`](../../../apps/hue/src/dsv_bench.d) — the phase decomposition above
- [`libs/ui/src/sparkles/ui/components/table/widgets.d`](../../../libs/ui/src/sparkles/ui/components/table/widgets.d) — `TableViewportSpec`
- [`libs/source-view/src/sparkles/source_view/markdown.d`](../../../libs/source-view/src/sparkles/source_view/markdown.d) — `MdTableExtras`
- [DSV preview spec](../../specs/hue/dsv-preview.md) — `DSN3`, `DSN4`

<!-- References -->
