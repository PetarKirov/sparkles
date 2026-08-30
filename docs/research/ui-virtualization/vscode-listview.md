# VS Code — `ListView` range diffing (TypeScript)

The most explicit **range-diff** in the catalog: each render computes the new
visible range, subtracts the previous one, and touches only the difference —
inserting, removing, or updating in place. The clearest possible statement of
"keep what is still there; change only what moved".

|                         |                                                                       |
| ----------------------- | --------------------------------------------------------------------- |
| **Language**            | TypeScript                                                            |
| **License**             | MIT                                                                   |
| **Repository**          | [microsoft/vscode][vscode] (pinned at [`474a349`][vscode-pin])        |
| **Category**            | Retained, DOM                                                         |
| **Rendering model**     | DOM elements positioned absolutely inside a translated rows container |
| **Virtualization unit** | Row index ↔ pooled DOM row keyed by `templateId`                      |

## Overview

### What it solves

The DOM is the extreme case of "constructing a view object is expensive": a few
thousand rows of real elements will stall a browser. Every VS Code list — the
explorer, the problems panel, IntelliSense, the settings tree — is one
`ListView` with a row cache underneath.

### Design philosophy

Three collaborating pieces, each with a single job:

- an **`IListVirtualDelegate`** answers `getHeight(element)` and
  `getTemplateId(element)` — the size and the _shape_ of a row;
- **renderers**, one per template id, own `renderTemplate` / `renderElement` /
  `disposeTemplate` — the same setup/bind split as
  [GTK 4](./gtk4-list-factories.md);
- a **`RangeMap`** turns the heights into a prefix-sum index so
  `indexAt(position)` and `positionAt(index)` are `O(log N)`.

The template id is the interesting refinement: a heterogeneous list (a tree with
files, folders and separators) pools each shape separately, so a recycled row is
always structurally compatible with the row it is about to become.

## How it works

`render` receives the _previous_ range and derives the work from set arithmetic:

```ts
protected render(previousRenderRange: IRange, renderTop: number, renderHeight: number, renderLeft: number | undefined, scrollWidth: number | undefined, updateItemsInDOM: boolean = false, onScroll: boolean = false): void {
	const renderRange = this.getRenderRange(renderTop, renderHeight);

	const rangesToInsert = Range.relativeComplement(renderRange, previousRenderRange).reverse();
	const rangesToRemove = Range.relativeComplement(previousRenderRange, renderRange);

	if (updateItemsInDOM) {
		const rangesToUpdate = Range.intersect(previousRenderRange, renderRange);

		for (let i = rangesToUpdate.start; i < rangesToUpdate.end; i++) {
			this.updateItemInDOM(this.items[i], i);
		}
	}

	const insertedItems: IItem<T>[] = [];

	this.cache.transact(() => {
		for (const range of rangesToRemove) {
			for (let i = range.start; i < range.end; i++) {
				this.removeItemFromDOM(i, onScroll);
			}
		}

		for (const range of rangesToInsert) {
			for (let i = range.end - 1; i >= range.start; i--) {
				this.insertItemInDOM(i);
				insertedItems.push(this.items[i]);
			}
		}
	});
	// …
	this.rowsContainer.style.top = `-${renderTop}px`;

	this.lastRenderTop = renderTop;
	this.lastRenderHeight = renderHeight;
}
```

— [`src/vs/base/browser/ui/list/listView.ts`][vscode-render]

Three sets, three treatments:

| Set                                 | Operation                                           | Cost                  |
| ----------------------------------- | --------------------------------------------------- | --------------------- |
| `renderRange \ previousRenderRange` | insert (allocate a row, render the element into it) | per newly-visible row |
| `previousRenderRange \ renderRange` | remove (release the row to the cache)               | per newly-hidden row  |
| `renderRange ∩ previousRenderRange` | update in place, and only when asked                | per still-visible row |

A one-notch scroll therefore inserts one row and removes one; the other ~40 rows
are untouched DOM. The whole content is positioned with a single
`rowsContainer.style.top = -renderTop`, so scrolling does not reposition
individual rows either.

The removals run before the insertions inside one `cache.transact`, so a row
leaving the top is available in the pool for the row entering the bottom — the
pool never grows beyond the window size plus churn.

Allocation goes through the cache, and the row records whether it needs
re-rendering:

```ts
const result = this.cache.alloc(item.templateId);
item.row = result.row;
item.stale ||= result.isReusingConnectedDomNode;
```

— [`src/vs/base/browser/ui/list/listView.ts`][vscode-insert]

## Analysis

### 1. What the window bounds

DOM construction, layout (implicitly, since the browser only lays out what
exists), paint, and the renderer's per-element work. The _data_ is an array
`this.items` that is fully present — VS Code virtualizes the view over a
materialized model, and pushes data laziness (a tree's unexpanded children) into
the model layer above.

### 2. How the range is computed

`RangeMap` prefix sums over per-item heights: `O(log N)` random access, so
`getRenderRange(renderTop, renderHeight)` is exact and cheap even for variable
heights. This is the third strategy from
[concepts § how the range is computed](./concepts.md#2-how-is-the-visible-range-computed),
and the reason VS Code can jump to an arbitrary scroll position instantly.

### 3. What survives between frames

`RowCache` (pooled DOM per template id), the `items` array with heights, the
`RangeMap`, and `lastRenderTop` / `lastRenderHeight` — the previous range, which
is the input to the next diff.

### 4. How the extent is known

**Exact**, from the `RangeMap`'s total. Heights come from the delegate without
measuring the DOM, so the extent is known before anything is rendered.

### 5. What breaks

- **A wrong `getHeight`** silently misaligns everything, because the browser is
  never consulted. Rows that measure differently need
  `setRowHeight`/`updateElementHeight` to re-enter the map.
- **Focus and selection** are tracked by index in the list, not by DOM node, so a
  recycled node carrying focus must be handled explicitly.
- **Stale rows**: `item.stale ||= result.isReusingConnectedDomNode` exists
  because a reused node may still be attached and displaying the previous
  element.
- **Horizontal scrolling** breaks the "heights are declared" assumption for
  widths, so `measureItemWidths` measures inserted items and updates the scroll
  width asynchronously.

## Strengths

- The range diff is the minimal correct amount of work, stated as three set
  operations.
- Prefix-sum heights give exact extents and `O(log N)` seeking with variable
  sizes — the strongest combination in the catalog.
- Template ids make pooling safe for heterogeneous lists.
- Container-level translation means a scroll moves one element, not `V`.

## Weaknesses

- Heights must be declared by the delegate; getting them wrong is silent.
- The data array is materialized, so very large data sets need a second
  virtualization layer above.
- Substantial machinery: range map, row cache, template ids, stale tracking.

## Key design decisions and trade-offs

| Decision                                             | Rationale                                                            | Trade-off                                                       |
| ---------------------------------------------------- | -------------------------------------------------------------------- | --------------------------------------------------------------- |
| Diff the render range against the previous one       | Touches only what changed; an in-view row is never rebuilt on scroll | Requires retaining the previous range and per-row identity      |
| Declared heights + `RangeMap` prefix sums            | Exact extent and `O(log N)` seek with variable heights               | Heights must be known without measuring; mistakes are invisible |
| Pool keyed by `templateId`                           | A reused row is structurally compatible by construction              | Heterogeneous lists keep several pools                          |
| Translate the container, not the rows                | One style write per scroll instead of `V`                            | Rows live in an absolutely-positioned coordinate space          |
| Update in place only when asked (`updateItemsInDOM`) | Scrolling need not touch rows whose content did not change           | Callers must know when an update is required                    |

## Sources

- [`src/vs/base/browser/ui/list/listView.ts`, `ListView.render`][vscode-render]
- [`src/vs/base/browser/ui/list/listView.ts`, `insertItemInDOM`][vscode-insert]

<!-- References -->

[vscode]: https://github.com/microsoft/vscode
[vscode-pin]: https://github.com/microsoft/vscode/tree/474a349ad5b745e512ef86b864d1c74f7264dd7a
[vscode-render]: https://github.com/microsoft/vscode/blob/474a349ad5b745e512ef86b864d1c74f7264dd7a/src/vs/base/browser/ui/list/listView.ts#L923
[vscode-insert]: https://github.com/microsoft/vscode/blob/474a349ad5b745e512ef86b864d1c74f7264dd7a/src/vs/base/browser/ui/list/listView.ts#L977
