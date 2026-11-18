# Hit-id registry

`sparkles.ui.hit_ids` issues the hit ids widgets carry, so no component
picks them by hand ([`INP27`, `INP28`](../../../specs/ui/input.md#hit-testing-inp10-inp27-inp28)).
An application owns one `HitRegistry`, calls `beginFrame` once at the top
of each frame, and every component that marks widgets hit-testable asks it
for a block.

| Symbol                               | Meaning                                                                                                                 |
| ------------------------------------ | ----------------------------------------------------------------------------------------------------------------------- |
| `HitKey(tag, instance)`              | What a block is asked for under: the component kind (`"editor.tabs"`) and which copy of it (`0` for a singleton)        |
| `HitBlock`                           | `length` ids from `base`; `HitBlock.init` is the empty block, issued to no one                                          |
| `block[i]`                           | The `i`-th id, or `0` (not hit-testable) past the end or in the empty block                                             |
| `block.id`                           | The first id: the id of a one-control block                                                                             |
| `block.contains(hit)`                | Whether `hit` is one of the block's ids                                                                                 |
| `block.indexOf(hit, out index)`      | The index of `hit` in the block, when it is one of its ids                                                              |
| `HitRegistry.beginFrame()`           | Start a frame: free every block the previous frame did not ask for                                                      |
| `HitRegistry.block(key, length = 1)` | The key's block: the one it holds, the same base frame after frame; a fresh one otherwise. The frame's largest ask wins |
| `HitRegistry.find(key)`              | The block `key` holds, without asking — what a press handler decodes against — or the empty block                       |
| `HitRegistry.ownerOf(hit, key, i)`   | The key holding `hit` and the index in its block                                                                        |
| `HitRegistryOf!stride`               | The registry with a chosen slot size; `HitRegistry` uses 2³² ids a slot on 64-bit targets and 2¹⁶ on 32-bit ones        |

## The rules a caller relies on

- **Blocks never overlap and never move.** Each key owns a slot of `stride`
  ids, so a block that grows keeps its base.
- **A held press keeps its target.** A freed slot is reused only after the
  fresh ones run out, the one freed longest ago first, so an id a press
  armed on one frame does not name another key's control on the release
  frame.
- **Slot 0 is never issued.** `0` means "not hit-testable", and the small
  literal ids of tests and examples live below `stride` without meeting an
  issued block.
- **A retained tree re-asks.** A component that rebuilds its widgets only
  when its data changes still asks for its keys every frame it is shown;
  asking is a lookup.

## Components that take blocks

The toolkit's views take a `HitBlock` where they once took a `hitBase`:
`treeView` and `viewSlice` (`hits[node]`), `propertyView` and
`inspectorView` (`hits[node]`), `viewHistory` (`HistoryViewOptions.hits`,
`hits[revision]`) and `viewCommandPalette` (`PaletteViewOptions.rowHits`,
the `i`-th listed row). `SettingsPane.claimHits(registry, instance)` asks
for the pane's own rows each frame it is shown.

```d
HitRegistry hits;

WidgetTree view(H)(ref H host)
{
    hits.beginFrame();
    const tabs = hits.block(HitKey("editor.tabs"), documents.length);
    foreach (i, doc; documents)
        row ~= b.add(Widget(kind: WidgetKind.text, text: doc.title, hitId: tabs[i]));
    // …
}

void press(size_t hit)
{
    size_t tab;
    if (hits.find(HitKey("editor.tabs")).indexOf(hit, tab))
        activate(tab);
}
```
