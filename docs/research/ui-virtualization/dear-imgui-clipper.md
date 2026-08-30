# Dear ImGui — `ImGuiListClipper` (C++)

The reference immediate-mode answer: a coarse clipper that tells the caller which
item indices to submit, so the per-frame cost tracks the viewport rather than the
list.

|                         |                                                                          |
| ----------------------- | ------------------------------------------------------------------------ |
| **Language**            | C++                                                                      |
| **License**             | MIT                                                                      |
| **Repository**          | [ocornut/imgui][imgui] (pinned at [`46d39d5`][imgui-pin])                |
| **Documentation**       | [`imgui.h`][clipper-h] · [Wiki][imgui-wiki]                              |
| **Category**            | Immediate mode, GPU                                                      |
| **Rendering model**     | Rebuild every frame; nothing retained but a small per-widget state store |
| **Virtualization unit** | Item index (`DisplayStart` … `DisplayEnd`)                               |

## Overview

### What it solves

Dear ImGui already clips. The clipper exists because clipping is not enough —
and the header says so in as many words:

> Dear ImGui already clip items based on their bounds but: it needs to first
> layout the item to do so, and generally **fetching/submitting your own data
> incurs additional cost**. Coarse clipping using `ImGuiListClipper` allows you
> to easily scale using lists with tens of thousands of items without a problem
>
> — [`imgui.h`][clipper-h]

Two costs are named there, and they are different. The first is the toolkit's
own layout of an item it will then discard. The second — **the application's cost
of fetching and submitting the data** — is not the toolkit's to optimize at all;
the only way to avoid it is to tell the application which indices to bother
with. That is the clipper's entire contract.

### Design philosophy

The clipper does not own the list, the data, or the widgets. It is a loop
driver: the caller writes an ordinary `for` loop over `DisplayStart ..
DisplayEnd` and submits ordinary widgets. Nothing about the item is retained
between frames, and there is no item object to recycle — consistent with the
immediate-mode premise that constructing a widget is nearly free and only
_data_ and _layout_ are worth avoiding.

## How it works

The documented usage is four lines:

```cpp
ImGuiListClipper clipper;
clipper.Begin(1000);         // We have 1000 elements, evenly spaced.
while (clipper.Step())
    for (int i = clipper.DisplayStart; i < clipper.DisplayEnd; i++)
        ImGui::Text("line number %d", i);
```

The `while`/`for` nesting is not decoration — it is how the clipper learns the
item height without being told:

> - Clipper lets you process the first element (`DisplayStart = 0`,
>   `DisplayEnd = 1`) regardless of it being visible or not.
> - User code submit that one element.
> - Clipper can measure the height of the first element
> - Clipper calculate the actual range of elements to display based on the
>   current clipping rectangle, position the cursor before the first visible
>   element.
> - User code submit visible elements.
>
> — [`imgui.h`][clipper-h]

So the first `Step()` is a **measurement pass over exactly one item**, and the
second is the real range. Once the height is known the range is a division,
exposed as a stateless helper:

```cpp
void ImGui::CalcClipRectVisibleItemsY(const ImRect& clip_rect, const ImVec2& pos,
                                      float items_height,
                                      int* out_visible_start, int* out_visible_end)
{
    *out_visible_start = ImMax((int)((clip_rect.Min.y - pos.y) / items_height), 0);
    *out_visible_end   = ImMax((int)ImCeil((clip_rect.Max.y - pos.y) / items_height),
                               *out_visible_start);
}
```

— [`imgui.cpp`][clipper-calc]

The skipped items are compensated for by advancing the layout cursor: "The
clipper calculates the range of visible items **and advance the cursor to
compensate for the non-visible items we have skipped**" ([`imgui.h`][clipper-h]).
That cursor advance is the virtual extent — it is what makes the scrollbar and
the content region agree with a list whose middle was never submitted.

## Analysis

### 1. What the window bounds

Build, layout **and** the application's data access. The clipper's value
proposition is explicitly the third one; the first two Dear ImGui could have
solved internally.

### 2. How the range is computed

Division by a uniform `ItemsHeight`, measured from the first submitted item
rather than declared. The struct carries `ItemsHeight` as `[Internal] Height of
item after a first step and item submission can calculate it`
([`imgui.h`][clipper-h]). Variable heights are outside the model — the
`ImGuiListClipperFlags_NoSetTableRowCounters` flag exists to break the
otherwise-implicit "1 clipper item == 1 table row" assumption.

### 3. What survives between frames

`ItemsHeight` and the cursor bookkeeping, via the per-context temp-data stack
(`TempData`). No item views: there is nothing to recycle because there are no
item objects.

### 4. How the extent is known

Declared indirectly — `Begin(items_count)` plus the measured height gives an
exact extent, and the cursor is advanced by it. This is the "declared" strategy
of [concepts § virtual extent](./concepts.md#virtual-extent) with the height
inferred rather than supplied.

### 5. What breaks

- **Non-uniform items.** The model is "lots evenly spaced items"; anything else
  needs `ImGuiListClipper::IncludeItemsByIndex` / manual stepping.
- **Keyboard navigation across the gap.** The clipper has to special-case it —
  "The clipper also handles various subtleties related to keyboard/gamepad
  navigation, wrapping etc." ([`imgui.h`][clipper-h]) — because nav wants to
  reach an item that was never submitted.
- **Frozen table rows.** `StartSeekOffsetY` exists to "Account for frozen rows in
  a table and initial loss of precision in very large windows"
  ([`imgui.h`][clipper-h]), and `Step()` carries a debug log for being called
  inside a frozen row. A pinned header interacts with the clipper's coordinate
  origin — the same interaction a frozen header row creates in any grid.

## Strengths

- Minimal contract: an item count in, an index range out. It composes with
  any data source because it never touches the data.
- The one honest statement in the corpus that _the application's_ data cost is
  the reason to virtualize, not the toolkit's.
- Zero retained per-item state, so no identity or staleness hazards from
  recycling.

## Weaknesses

- Uniform heights only, in the common path.
- The measure-one-item-first protocol leaks into the caller's loop structure
  (`while (Step())` around the `for`), which is surprising the first time.
- Precision: very tall windows needed a dedicated `double StartSeekOffsetY`
  field to stay accurate.

## Key design decisions and trade-offs

| Decision                                                    | Rationale                                                             | Trade-off                                                  |
| ----------------------------------------------------------- | --------------------------------------------------------------------- | ---------------------------------------------------------- |
| Return an index range, own nothing                          | Lets the caller avoid its own data cost, which the toolkit cannot see | The caller must structure its loop around the clipper      |
| Measure the first item instead of taking a height parameter | Works without the caller knowing its own row metrics                  | Costs one extra step and assumes item 1 is representative  |
| Advance the layout cursor over skipped items                | The scrollbar and content region stay correct for free                | Ties the clipper to a single-axis, uniformly-spaced layout |
| No item objects, no pool                                    | Nothing to invalidate; no state to reset                              | Rebuild cost per visible item is paid every frame          |

## Sources

- [`imgui.h`, `ImGuiListClipper` declaration and usage comment][clipper-h]
- [`imgui.cpp`, `ImGui::CalcClipRectVisibleItemsY`][clipper-calc]
- [Dear ImGui wiki][imgui-wiki]

<!-- References -->

[imgui]: https://github.com/ocornut/imgui
[imgui-pin]: https://github.com/ocornut/imgui/tree/46d39d56febc2a00bdd2270dc88c8a13f2a0441a
[clipper-h]: https://github.com/ocornut/imgui/blob/46d39d56febc2a00bdd2270dc88c8a13f2a0441a/imgui.h#L2877
[clipper-calc]: https://github.com/ocornut/imgui/blob/46d39d56febc2a00bdd2270dc88c8a13f2a0441a/imgui.cpp#L3604
[imgui-wiki]: https://github.com/ocornut/imgui/wiki
