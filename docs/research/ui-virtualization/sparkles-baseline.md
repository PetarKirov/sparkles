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

## What is not virtualized — the measurement

`apps/hue/src/dsv_bench.d` decomposes one scroll notch. Corpus: a
`files.csv`-shaped table, 3012 rows × 8 columns (~200 KiB), window 48 rows.
LDC 1.42, `dub test` (debug build — the absolute numbers are pessimistic, the
proportions are the point). Median per iteration:

| Phase                                               | Scope                |     Median | Bounded by the window? |
| --------------------------------------------------- | -------------------- | ---------: | ---------------------- |
| **`sniff`**                                         | 256 KiB sample       | **9.4 ms** | ✗                      |
| `parseDsv`                                          | whole file           |     1.6 ms | ✗                      |
| `applyProjection`, no sort                          | whole file           |      63 µs | ✗                      |
| `applyProjection`, **one sort key**                 | whole file           |  **27 ms** | ✗                      |
| `detectHeader`                                      | bounded              |      35 µs | n/a                    |
| `inferColumnTypes`                                  | 100 records          |      35 µs | n/a                    |
| `adaptDsv` **with** a 48-row window                 | model + build        |  **11 ms** | partly                 |
| `adaptDsv` with no window (pre-`DSN4`)              | model + build        |      16 ms | ✗                      |
| `adaptDsv`, windowed, over a 100-row file           | model + build        |    0.57 ms | —                      |
| `previewOf`                                         | window               |       2 µs | ✓                      |
| `remateralizeWindow` (view + layout + display list) | window               | **4.8 ms** | ✓                      |
| **one scroll notch, total**                         | model + build + view |  **16 ms** |                        |

Three findings follow, and they reorder the work:

1. **The sniffer is the single largest cost in a scroll notch — 9.4 ms of
   16 ms — and it is pure waste.** `adaptDsv` re-sniffs the dialect on every
   call even though the caller already resolved it and passes it back in as
   flags; the sniff's verdict is then overridden. `sniffMaxBytes` is 256 KiB, so
   for any file up to that size the "bounded sample" is the whole file.

2. **The view half is the smaller half.** Building the widget tree, laying it
   out and producing the display list for a 48-row window costs 4.8 ms — 30% of
   the notch. Retaining that tree and mutating cells (the
   [VS Code range-diff](./vscode-listview.md) or
   [GTK bind](./gtk4-list-factories.md) approach) can attack at most that 30%,
   and only the part of it that is genuinely redundant.

3. **Under an active sort, the model half is catastrophic.** `applyProjection`
   with one sort key costs 27 ms — more than everything else combined — because
   the comparator decodes cells on every comparison, so a sorted view re-sorts
   the entire file on every scroll notch. The same permutation is recomputed
   identically each time.

The two `adapt-window` rows bracket the waste directly: the same 48-row window
costs **0.57 ms** over a 100-row file and **11 ms** over a 3012-row file. Since
the _build_ is identical, the 10.4 ms difference is entirely the unbounded model
work.

> [!NOTE]
> Writing this benchmark surfaced a trap worth recording: `benchIter` does not
> run its body, it _registers_ it, and the runner executes it after the enclosing
> `unittest` has returned. A fixture that lives in that frame is therefore already
> destructed by the time it is timed — a `DsvDoc`'s `SmallBuffer` members release
> their storage and zero their lengths, so the document reads back **empty** and
> the leg silently measures nothing. Plain scalars survive (freed stack memory
> keeps its bytes), which is what makes it look like a data bug rather than a
> lifetime one. Every fixture here is a `class` so the GC keeps it alive, and the
> legs assert their row counts.

## Analysis against the spine

### 1. What the window bounds

**Build, layout and paint — not data.** Every scroll re-sniffs, re-parses and
re-projects the entire file. In the catalog's terms sparkles is where
[Ratatui](./ratatui-offsets.md) is (a bounded view over a fully-materialized
model), except that sparkles re-materializes the model itself per frame, which
Ratatui does not.

### 2. How the range is computed

Division: the grid's row height is one line, so `windowStart` comes straight from
the table's scroll offset. Exact, `O(1)`, and legitimate — the uniformity
assumption that [egui](./egui-show-rows.md) makes is _true_ here rather than
assumed.

### 3. What survives between frames

The raw bytes, the projection spec, the scroll offset, and the interaction
machines that `remateralizeWindow` deliberately preserves (`barSv`,
`tableScrollAt`, folds). **Not** the parse, **not** the permutation, **not** the
widget tree.

### 4. How the extent is known

Declared and exact, via `virtualLines` / `virtualOffset`.

### 5. What breaks

- The window offset must be applied everywhere a view coordinate becomes a data
  coordinate — already fixed for copy, and a standing obligation for every new
  feature.
- Scroll latency is dominated by re-derivation, not by rendering.
- A sorted or filtered view multiplies that re-derivation cost.

## The delta

| Capability                              | Prior art                                                                                                                                                     | Sparkles today                                                                |
| --------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- |
| Bounded build                           | universal                                                                                                                                                     | ✓ `DsvWindow` (`DSN4`)                                                        |
| Exact virtual extent                    | [egui](./egui-show-rows.md), [Slint](./slint-repeater.md), [VS Code](./vscode-listview.md)                                                                    | ✓ `virtualLines` / `virtualOffset`                                            |
| Overscan band                           | [Flutter](./flutter-slivers.md), [WPF](./avalonia-wpf-virtualizing-panels.md), [Qt Quick](./qt-quick-listview.md)                                             | ✓ `+8` rows                                                                   |
| Stable geometry across scroll           | rare — most estimate                                                                                                                                          | ✓ `DSN3` pinned widths (stronger than the field)                              |
| Window-offset identity correction       | [egui](./egui-show-rows.md), [Flutter](./flutter-slivers.md)                                                                                                  | ✓ `windowStart` / `virtualRowOffset`                                          |
| **Persistent model, queried per index** | [Qt](./qt-quick-listview.md), [GTK](./gtk4-list-factories.md), [Flutter](./flutter-slivers.md), [Slint](./slint-repeater.md), [VS Code](./vscode-listview.md) | ✗ **re-derived per scroll**                                                   |
| **Cached projection (sort/filter)**     | implied by every model protocol                                                                                                                               | ✗ **recomputed per scroll**                                                   |
| View reuse across scroll (recycling)    | [GTK](./gtk4-list-factories.md), [Qt](./qt-quick-listview.md), [WPF](./avalonia-wpf-virtualizing-panels.md), [VS Code](./vscode-listview.md)                  | ✗ (and see [`comparison.md`](./comparison.md) for whether it is worth having) |

## Sources

- [`apps/hue/src/dsv_view.d`](../../../apps/hue/src/dsv_view.d) — `adaptDsv`, `DsvWindow`, `sampledColumnWidths`, `DsvCopy`
- [`apps/hue/src/workspace.d`](../../../apps/hue/src/workspace.d) — `applyDsvBrowser`, `dsvWindowRows`, `dsvGridTop`
- [`apps/hue/src/viewer_model.d`](../../../apps/hue/src/viewer_model.d) — `remateralizeWindow`, `rebuildTree`
- [`apps/hue/src/dsv_bench.d`](../../../apps/hue/src/dsv_bench.d) — the phase decomposition above
- [`libs/ui/src/sparkles/ui/components/table/widgets.d`](../../../libs/ui/src/sparkles/ui/components/table/widgets.d) — `TableViewportSpec`
- [`libs/source-view/src/sparkles/source_view/markdown.d`](../../../libs/source-view/src/sparkles/source_view/markdown.d) — `MdTableExtras`
- [DSV preview spec](../../specs/hue/dsv-preview.md) — `DSN3`, `DSN4`

<!-- References -->
