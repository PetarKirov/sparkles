# Tree-View Case Study

A comparative analysis of tree-view implementations in TUI libraries, evaluating their designs through the lens of [Sean Parent's principles][sean-parent-index] (value semantics, avoiding incidental data structures, separating algorithms from data) and the project's D guidelines ([Design by Introspection][dbi-guidelines], [functional/declarative style][functional-guidelines]). The two primary references are **snacks.nvim's explorer** and **ratatui-tree-widget**, with cross-references to other libraries from the [TUI catalog][tui-index].

## Contents

1. [Introduction](#1-introduction)
2. [Snacks.nvim Explorer — Deep Dive](#2-snacksnvim-explorer--deep-dive)
3. [ratatui-tree-widget — Deep Dive](#3-ratatui-tree-widget--deep-dive)
4. [Cross-Library Tree Patterns](#4-cross-library-tree-patterns)
5. [Comparative Analysis](#5-comparative-analysis)
6. [Analysis Through Sean Parent's Principles](#6-analysis-through-sean-parents-principles)
7. [Design Principles for Sparkles Tree-View](#7-design-principles-for-sparkles-tree-view)

---

## 1. Introduction

This document is a case study informing the design of a generic tree-view component for Sparkles. It examines how existing TUI libraries solve the core problems of tree display:

- **Data model** — how tree nodes are represented and related
- **Traversal** — how the tree is walked for rendering
- **Flatten** — how a hierarchical structure becomes a linear list of visible rows
- **Expand/collapse** — where the "opened" state lives and how it affects traversal
- **Filtering** — how nodes are included or excluded
- **Virtual scroll** — how large trees render only visible rows
- **Status decoration** — how per-node metadata (git, diagnostics) propagates

The two primary case studies — snacks.nvim's explorer and ratatui-tree-widget — represent opposite ends of the design spectrum. Snacks is a large, feature-rich file explorer embedded in Neovim that reuses picker infrastructure. ratatui-tree-widget is a small, focused Rust library that cleanly separates data, state, and rendering into three types. Both have lessons for a D implementation.

---

## 2. Snacks.nvim Explorer — Deep Dive

Source: `/home/petar/code/repos/neovim/snacks.nvim/lua/snacks/explorer/`

### "A picker in disguise"

The explorer's `init.lua` declares itself:

```lua
M.meta = {
  desc = "A file explorer (picker in disguise)",
}
```

Rather than implementing its own list rendering, scrolling, filtering, and input handling, the explorer reuses the picker infrastructure (finder → matcher → list → layout). The tree is a data source that produces a flat stream of items for the picker to display. This means the explorer gets fuzzy matching, virtual-scroll rendering, keyboard navigation, and preview for free. The trade-off is that the tree data model must conform to the picker's item interface.

### Tree data model

`explorer/tree.lua` defines a singleton `Tree` with `Node` objects:

```lua
---@class snacks.picker.explorer.Node
---@field path string
---@field name string
---@field type "file"|"directory"|"link"|...
---@field dir? boolean
---@field open? boolean           -- user intent: should this directory be expanded?
---@field expanded? boolean       -- filesystem state: have children been read?
---@field hidden? boolean         -- name starts with "."
---@field ignored? boolean        -- git-ignored
---@field status? string          -- merged git status
---@field severity? number        -- LSP diagnostic severity
---@field parent? Node            -- back-reference
---@field children table<string, Node>  -- name-keyed child table
---@field last? boolean           -- is last child of parent (for tree-drawing glyphs)
---@field utime? number           -- expansion timestamp
```

The tree is a singleton — `tree.lua` returns `Tree.new()` at module scope, so all explorer instances share the same tree. Nodes are identified by their filesystem path (stored in `Tree.nodes` as a `path → Node` lookup table). The `parent` field is a direct Lua reference to the parent node, creating a doubly-linked tree.

### Lazy expansion

The `open` and `expanded` fields represent two different concepts:

- **`open`** — user intent. Set by `Tree:open(path)`, cleared by `Tree:close(path)`. Indicates the user wants this directory expanded.
- **`expanded`** — filesystem state. Set by `Tree:expand(node)` after `uv.fs_scandir` reads the directory contents. Cleared on refresh.

This separation allows the tree to know which directories _should_ be expanded without having read them yet. `Tree:get()` lazily expands directories during the walk:

```lua
if n.dir and n.open and not n.expanded and opts.expand ~= false then
  self:expand(n)
end
```

`expand()` calls `uv.fs_scandir` to read directory entries, creates child nodes via `Tree:child()`, and removes stale entries no longer on disk.

### Tree → flat list conversion

`Tree:get(cwd, cb, opts)` is the bridge between the tree and the picker. It walks the tree depth-first, calling `cb(node)` for each visible node. The picker's finder wraps this into a flat item stream:

```lua
Tree:get(ctx.filter.cwd, function(node)
  local item = {
    file = node.path,
    dir = node.dir,
    open = node.open,
    parent = parent,  -- reference to parent item (for indentation)
    status = ...,
    severity = ...,
  }
  cb(item)
end, filter_opts)
```

The picker list receives these items as a flat sequence. Indentation is derived from the `parent` chain — the formatter walks `item.parent` references to compute depth.

### DFS walk with sorting

`Tree:walk(node, fn, opts)` performs the depth-first traversal. Children are sorted inline: directories first, then alphabetical by name:

```lua
local children = vim.tbl_values(node.children)
table.sort(children, function(a, b)
  if a.dir ~= b.dir then
    return a.dir  -- directories first
  end
  return a.name < b.name
end)
```

The walk yields each directory node before descending into its children (pre-order). The `fn` callback returns `false` to skip a subtree or `true` to abort the entire walk.

### Filtering

`Tree:filter(filter)` returns a predicate function. The filter respects `hidden`, `ignored`, and `exclude`/`include` globs. The `include` list takes precedence — a file matching an include glob is shown even if it's hidden or ignored:

```lua
return function(node)
  if include and include(node.path) then return true end
  if node.hidden and not filter.hidden then return false end
  if node.ignored and not filter.ignored then return false end
  if exclude and exclude(node.path) then return false end
  return true
end
```

### Git status propagation

`explorer/git.lua` runs `git status --porcelain=v1 -z` asynchronously via `uv.spawn`, parses the output, and applies per-file status to tree nodes. Status is propagated upward to parent directories:

```lua
for dir in Snacks.picker.util.parents(path, cwd) do
  add_git_status(dir, s.status)
end
```

The `add_git_status` function merges statuses — a directory's status is the "worst" status among its children. Before applying new status, the module takes a snapshot of current `status` and `ignored` fields; after applying, it compares via `Tree:changed()` to determine if a re-render is needed.

### Diagnostics propagation

`explorer/diagnostics.lua` follows the same pattern: it reads `vim.diagnostic.get()`, applies severity to file nodes, and propagates the minimum severity upward to parent directories. The snapshot/changed mechanism avoids unnecessary re-renders.

### File watching

`explorer/watch.lua` uses `uv_fs_event_t` handles:

- Open directories get a watch that triggers `Tree:refresh(path)` + debounced picker refresh.
- The `.git/index` file gets a watch that triggers `Git.refresh()` on index changes.
- Watches are reconciled on each `watch()` call — unused watches (for closed directories) are stopped.

The refresh is debounced at 100ms via a `uv_timer_t` to batch rapid filesystem changes.

### Search mode

When the user types a search query, the explorer switches from tree-walk finder to an `fd`-based finder:

```lua
if state:setup(ctx) then
  ctx.picker.matcher.opts.keep_parents = true
  return M.search(opts, ctx)
end
```

The search finder runs `fd --type d --path-separator /` to find files and directories matching the query. Parent directories of matched files are synthesized as "internal" items so the tree structure is preserved. The matcher is configured with `keep_parents=true` to avoid filtering out ancestor directories of matched files.

Hierarchical sort keys ensure correct visual ordering in search results:

```lua
if item.dir then
  item.sort = parent.sort .. "!" .. basename .. " "
else
  item.sort = parent.sort .. "#" .. basename .. " "
end
```

The `!` prefix for directories sorts them before `#`-prefixed files at each level.

### Snapshot diffing

`Tree:snapshot(node, fields)` captures the current state of a subtree as a `{node → [field_values]}` table. `Tree:changed(node, snapshot)` compares against a previous snapshot. This is used in both git and diagnostics modules to detect whether the tree state has actually changed, avoiding unnecessary picker refresh cycles.

---

## 3. ratatui-tree-widget — Deep Dive

Source: `/home/petar/code/repos/rust/tui-rs-tree-widget/src/`

### Three-layer architecture

ratatui-tree-widget cleanly separates concerns into three types:

| Type                                                 | File            | Role                                               |
| ---------------------------------------------------- | --------------- | -------------------------------------------------- |
| `TreeItem<'text, Identifier>`                        | `tree_item.rs`  | Data model — tree structure and content            |
| [`TreeState<Identifier>`][ratatui-tree-widget-state] | `tree_state.rs` | Interaction state — opened, selected, scroll       |
| `Tree<'a, Identifier>`                               | `lib.rs`        | Rendering widget — visual configuration and output |

This separation is the library's central design insight. The data model knows nothing about selection or rendering. The state knows nothing about visual symbols or styles. The widget borrows both and produces output.

### TreeItem — data model

```rust
#[derive(Debug, Clone)]
pub struct TreeItem<'text, Identifier> {
    pub(super) identifier: Identifier,
    pub(super) text: Text<'text>,
    pub(super) children: Vec<Self>,
}
```

Key design choices:

- **Generic Identifier** constrained to `Clone + PartialEq + Eq + Hash`. This enables path-based identification (e.g., `vec!["src", "main.rs"]`) without committing to a specific type. The constraint set matches what D would express as `opEquals` + `toHash`.
- **Unique-sibling enforcement**: Both `new()` and `add_child()` collect child identifiers into a `HashSet` and reject duplicates with an error. This is an invariant enforced at construction time.
- **Recursive ownership**: Children are `Vec<Self>`, making the tree a value type. `#[derive(Clone)]` gives the entire tree copy semantics.
- **Variable-height items**: `height()` delegates to `Text::height()`, supporting multi-line tree items.

The identifier is deliberately separate from the display text — the doc comment uses a filename analogy: `main.rs` is the identifier while `main` might be the displayed text.

### TreeState — interaction state

```rust
pub struct TreeState<Identifier> {
    pub(super) offset: usize,
    pub(super) opened: HashSet<Vec<Identifier>>,
    pub(super) selected: Vec<Identifier>,
    pub(super) ensure_selected_in_view_on_next_render: bool,

    pub(super) last_area: Rect,
    pub(super) last_biggest_index: usize,
    pub(super) last_identifiers: Vec<Vec<Identifier>>,
    pub(super) last_rendered_identifiers: Vec<(u16, Vec<Identifier>)>,
}
```

The critical design: **opened nodes are stored as a `HashSet<Vec<Identifier>>`** — a set of full paths from root. This is not a field on the tree nodes themselves. The opened set is purely interaction state.

The `selected` field is a single `Vec<Identifier>` representing the path to the currently selected node.

Navigation methods operate on the cached `last_identifiers` from the previous render:

- **`key_up()`/`key_down()`** — move selection by one position in the flattened list.
- **`key_left()`** — close the current node if open; if already closed, select the parent (pop from `selected`).
- **`key_right()`** — open the current node.
- **`toggle_selected()`** — toggle open/close.
- **`select_relative(F)`** — apply a user-defined function to compute the new index.

Mouse support uses `last_rendered_identifiers` — a list of `(y_coordinate, identifier)` pairs cached from the previous render:

- **`rendered_at(Position)`** — reverse-lookup: find which node was rendered at a screen position.
- **`click_at(Position)`** — select the node at a position; if already selected, toggle it.

### Flatten — the bridge algorithm

```rust
pub struct Flattened<'text, Identifier> {
    pub identifier: Vec<Identifier>,
    pub item: &'text TreeItem<'text, Identifier>,
}

pub fn flatten<'text, Identifier>(
    open_identifiers: &HashSet<Vec<Identifier>>,
    items: &'text [TreeItem<'text, Identifier>],
    current: &[Identifier],
) -> Vec<Flattened<'text, Identifier>>
```

This is a **free function**, not a method on `TreeItem` or `TreeState`. It takes the opened set and the tree data as inputs and produces a flat list of visible nodes. The algorithm:

1. Iterate over sibling items.
2. For each item, build its full path by appending its identifier to `current`.
3. Check if `open_identifiers` contains this path. If so, recursively flatten children.
4. Emit the item, then emit any child results.

Depth is derived, not stored: `depth() = identifier.len() - 1`. A top-level item has a path of length 1, so depth 0.

The flatten function is pure — given the same tree and opened set, it always produces the same output. This makes it testable in isolation:

```rust
#[test]
fn depth_works() {
    let mut open = HashSet::new();
    open.insert(vec!["b"]);
    open.insert(vec!["b", "d"]);
    let depths = flatten(&open, &TreeItem::example(), &[])
        .into_iter()
        .map(|flattened| flattened.depth())
        .collect::<Vec<_>>();
    assert_eq!(depths, [0, 0, 1, 1, 2, 2, 1, 0]);
}
```

### Tree — rendering widget

```rust
pub struct Tree<'a, Identifier> {
    items: &'a [TreeItem<'a, Identifier>],
    block: Option<Block<'a>>,
    scrollbar: Option<Scrollbar<'a>>,
    style: Style,
    highlight_style: Style,
    highlight_symbol: &'a str,
    node_closed_symbol: &'a str,    // default: "▶ "
    node_open_symbol: &'a str,      // default: "▼ "
    node_no_children_symbol: &'a str, // default: "  "
}
```

The widget **borrows** `&[TreeItem]` — it does not own the data. Visual configuration is set via builder methods. It implements ratatui's `StatefulWidget` trait, meaning `render()` takes a `&mut TreeState`.

The render pipeline:

1. **Flatten**: `state.flatten(items)` produces the flat list of visible nodes.
2. **Compute scroll viewport**: Forward-scan from `offset`, accumulate item heights until the area is filled. If `ensure_selected_in_view` is set, expand the window to include the selected item.
3. **Render visible items**: For each item in the viewport:
   - Write highlight symbol (if selected).
   - Write indent: `depth * 2` spaces.
   - Write node symbol: leaf (`"  "`), open (`"▼ "`), or closed (`"▶ "`).
   - Write the item's text content.
4. **Cache state**: Store `last_identifiers` and `last_rendered_identifiers` for next-frame navigation.

The scroll viewport handles variable-height items. The ensure-selected-in-view logic expands the viewport in both directions, potentially adjusting `start` upward to keep the selected item visible.

---

## 4. Cross-Library Tree Patterns

Coverage of tree-related patterns from other studied libraries. See the [TUI catalog][tui-index] and [comparison][comparison] for full details.

### [ImTui][imtui] / Dear ImGui (C++)

Immediate-mode tree via `ImGui::TreeNode()` / `TreePop()`. There is no data model — the tree structure is implicit in the call sequence. Expand/collapse state is managed by ImGui's internal hot/active state keyed by string IDs. This is the simplest possible tree API but offers no model for external algorithms to operate on.

### [Textual][textual] (Python)

Textual provides built-in `Tree[TreeDataType]` and `TreeNode[TreeDataType]` widgets with a rich feature set.

**Data model.** `TreeNode` stores `_id: NodeID` (auto-incrementing int), `_label: Text` (Rich styled text), `data: TreeDataType | None` (generic user payload), `_parent`, `_children: list[TreeNode]`, `_expanded: bool`, and `_allow_expand: bool`. A global `_tree_nodes: dict[NodeID, TreeNode]` provides O(1) lookup by ID.

**Flatten pipeline.** The `_build()` method performs lazy DFS, producing a flat list of `_TreeLine` objects. Each `_TreeLine` contains a `path: list[TreeNode]` (full ancestor chain from root) and a `last: bool` flag. The `path` list drives guide character rendering — at each depth level, the renderer selects a guide based on whether the ancestor at that depth was the last child of its parent. The flat list is cached in `_tree_lines_cached` and invalidated (set to `None`) on any structural change.

**Two-level caching.** Beyond the structural cache, an `LRUCache[LineCacheKey, Strip]` caches rendered lines. The cache key incorporates the node's `_updates` counter, hover state, selected state, and available width. A node label change increments only that node's counter, invalidating its cached line without rebuilding the entire flat list.

**Virtual scroll.** `Tree` extends `ScrollView`, inheriting virtual scrolling. It advertises a `virtual_size` based on total line count and maximum width. Only lines within the viewport trigger `render_line(y)` calls.

**Lazy loading (DirectoryTree).** `DirectoryTree` extends `Tree[DirEntry]` and adds a queue-based background worker: expanding a directory pushes it to `_load_queue`, a `@work(thread=True)` coroutine dequeues and populates children via filesystem reads. State preservation on reload captures expanded paths and cursor position, re-expands after repopulating, and restores cursor to the nearest valid position.

**Expand/collapse state** lives on the node (`_expanded` bool) — not separated into an external state object. This is the canonical retained-mode pattern but limits the tree to a single visual state.

### Rich (Python) — Tree rendering

Rich's `Tree` is a non-interactive renderable — it produces styled text output, not a navigable widget. Its guide character rendering algorithm is the clearest model among all studied libraries.

**Data model.** Each `Tree` node holds a `label` (any Rich renderable), `children: list[Tree]`, `style`/`guide_style`, and `expanded: bool`. Styles cascade from parent to child by default.

**Guide character model.** Four positional constants indexed as a tuple:

| Index | Name     | Meaning                                                 |
| ----- | -------- | ------------------------------------------------------- |
| 0     | SPACE    | Empty gap (no vertical line needed)                     |
| 1     | CONTINUE | Vertical continuation line (`│`) — sibling exists below |
| 2     | FORK     | Branch point (`├──`) — this node has a sibling below    |
| 3     | END      | Terminal branch (`└──`) — last child                    |

Four character sets are provided: ASCII, Unicode, Bold Unicode (`┣━━`/`┗━━`), and Double Unicode (`╠══`/`╚══`). The guide set is selected by inspecting the `guide_style` — bold style yields bold guides, underline2 yields double-line guides.

**Rendering algorithm.** A stack-based DFS with a `levels` list accumulator. For each visible node:

1. Build prefix by concatenating `levels[0..depth]` — this gives the vertical connectors for all ancestor levels.
2. At the current depth, select FORK (not last child) or END (last child).
3. Update `levels[depth]` to CONTINUE (more siblings) or SPACE (was last child).
4. For multi-line labels, the first line gets the FORK/END connector; subsequent lines get the appropriate CONTINUE/SPACE prefix at the current depth.

This four-state model with per-depth-level accumulation is the canonical algorithm for tree guide rendering.

### [broot][broot] (Rust) — Tree as search result

A terminal file navigator that treats the tree as a function of the search pattern. Its architecture is fundamentally different from expand/collapse-based trees. (See [detailed broot study][broot].)

**Data model.** The tree is a flat `Vec<TreeLine>` — no recursive structure. Each `TreeLine` stores `id`, `parent_id: Option<usize>`, `depth: u16`, `score: i32`, and `left_branches: Box<[bool]>`. There are no child pointers. The `left_branches` array is precomputed during construction: `left_branches[d]` is `true` if the ancestor at depth `d` has more siblings below, determining whether a vertical continuation line (`│`) should be drawn at that depth.

**Construction via BFS with scoring.** `TreeBuilder` performs breadth-first filesystem traversal with two queues (`open_dirs` for the current level, `next_level_dirs` for the next). Each entry is scored against the active search pattern. The builder stops early at `targeted_size` (roughly screen height) without a pattern, or `10 * targeted_size` with a pattern. Excess entries are pruned via a min-heap (`SortableBId`) — the lowest-scoring entries are discarded first. An intermediate `BLine` arena with child pointers is used during construction but discarded when the final `Vec<TreeLine>` is produced.

**"Tree as search result" paradigm.** Filtering is not post-processing over a pre-built tree. The pattern is evaluated during BFS construction. Subtrees with no matches are pruned entirely. Each keystroke rebuilds the tree structure from the filesystem — the tree is always a function of `(filesystem_state, search_pattern, depth_limit)`.

**No expand/collapse.** broot has no per-node expand/collapse state. Depth is controlled globally via `max_depth`. Truncated content is shown as synthetic `Pruning` lines ("N unlisted") that are not selectable. A dual-tree model — `tree` (base) and optional `filtered_tree` — supports toggling between filtered and unfiltered views.

**No virtual scroll.** The BFS early-termination strategy bounds the line count to approximately screen height, so virtual scrolling is unnecessary. Scrolling is a simple `scroll: usize` offset. A `Dam` cancellation mechanism interrupts builds when the user types, keeping the UI responsive on large filesystems.

### cursive_tree_view (Rust)

A tree-view widget for the [Cursive][cursive] TUI framework that validates the flat-array approach to tree storage.

**Data model.** The tree is stored as a flat `Vec<TreeNode<T>>` where `T: Display + Debug`. Each `TreeNode` stores `value: T`, `level: usize` (depth), `is_collapsed: bool`, `children: usize` (descendant count), and `height: usize` (subtree size including self). Parent-child relationships are implicit — a node's children occupy the contiguous indices immediately after it. Parent lookup is a backward scan for the first entry with a strictly lower `level`.

**Dual index spaces.** The crate maintains two identification schemes:

- **Item index** — position in the flat `Vec`. Stable across collapse/expand.
- **Row** — position in the visible display. Changes when nodes above are collapsed/expanded.

All public API methods use row indices. Internal conversion between the two is O(n): `row_to_item_index()` walks the array, skipping collapsed subtrees.

**Collapse mechanics.** Collapsed nodes remain in the `Vec` — they are skipped during rendering, not removed. The `collapsed_height` field caches how many rows are hidden. Height changes propagate upward via `traverse_up()`, which walks ancestors to adjust their counts.

**Rendering.** The `draw()` method performs a single forward scan of the `Vec`, incrementing by `node.len()` to skip collapsed subtrees. Each node renders at `level * 2` indentation with symbols: `"▸"` (collapsed), `"▾"` (expanded), `"◦"` (leaf).

**Placement-based insertion.** An enum `Placement { After, Before, FirstChild, LastChild, Parent }` specifies where new nodes are inserted relative to a target row.

**Tradeoffs.** Row-based public identification is fragile — insert/remove above a node changes its row index. No stable node IDs exist. Parent lookup is O(siblings). But cache-friendly iteration, simple serialization, and no recursive types are significant advantages for `@nogc` constraints.

### stlab::forest (C++) — Sean Parent's tree container

Sean Parent's own answer to the "incidental data structure" problem for trees.

**Node structure.** Each node stores a 2×2 link array: `_nodes[leading|trailing][prior|next]`. The leading edge represents "entering" a node (pre-order visit); the trailing edge represents "leaving" (post-order visit). This dual-edge model is the central abstraction — every node is visited twice in a fullorder traversal.

**Memory layout.** Nodes are individually heap-allocated and linked into a circular doubly-linked structure anchored by a sentinel tail node. This gives O(1) insert/erase via splice but poor cache locality due to pointer chasing.

**Iterator hierarchy.** The forest provides five iterator types, all derived from fullorder:

| Iterator                              | Description                                                             |
| ------------------------------------- | ----------------------------------------------------------------------- |
| `forest_iterator` (fullorder)         | Visits every node twice (leading then trailing)                         |
| `child_iterator`                      | Immediate children of a node                                            |
| `edge_iterator<leading>` (preorder)   | Leading edges only                                                      |
| `edge_iterator<trailing>` (postorder) | Trailing edges only                                                     |
| `depth_fullorder_iterator`            | Fullorder with depth tracking (leading increments, trailing decrements) |

The `depth_fullorder_iterator` filtered to leading edges is directly applicable to tree rendering — it yields `(node, depth)` pairs in preorder, exactly what a tree renderer needs for indentation.

**Value semantics on the container.** `forest<T>` supports deep copy via traversal-based reconstruction and move. There is a single "whole" object with clear ownership. No parent pointers on nodes — parent navigation is implicit in the traversal order.

**Relevance.** stlab::forest solves the ownership and value semantics problems but uses individual heap allocations, trading cache locality for O(1) structural modification and stable iterators. The flat-array approach (contiguous `Node[]` with indices) reverses this tradeoff: better cache locality and `@nogc` friendliness, but O(n) insertion.

### [Brick][brick] (Haskell)

No built-in tree widget. Functional combinators (`vBox`, `padLeft`) compose a tree visually. The tree model is user-defined — Brick provides the layout primitives, and the application builds tree display from those primitives. This is the most "library, not framework" approach.

### [Bubble Tea][bubbletea] (Go)

No built-in tree widget. Community `bubbles/tree` follows the MVU pattern: the model stores a flat list of visible nodes annotated with depth. Expand/collapse dispatches an update message that recomputes the flat list. Pure functional approach where the view is derived from the model.

### [tview][tview] (Go)

`TreeView` widget with `TreeNode` model. Nodes have a `reference` field (user data), `children` slice, and `expanded` boolean. Virtual scrolling via a `GetChildren` callback enables lazy loading. The expand/collapse state lives directly on the node — mixing data and view state.

### [FTXUI][ftxui] (C++)

No built-in tree widget. Flexbox layout + `Collapsible()` component can compose one. `Collapsible(label, child)` toggles visibility of its child on click. Building a full tree requires nesting collapsibles, which is verbose but gives full control over rendering.

### [Nottui][nottui] (OCaml)

Incremental reactive model ideal for trees. Reactive variables (`Lwd.var`) for expand/collapse state trigger minimal recomputation of only the affected subtree. The DAG-based computation model means expanding a deep node doesn't recompute siblings. This is architecturally the most sophisticated approach for large trees.

---

## 5. Comparative Analysis

| Dimension             | Snacks.nvim                       | ratatui-tree-widget               | broot                            | cursive_tree_view                        | Textual                  | Rich                            | stlab::forest                   |
| --------------------- | --------------------------------- | --------------------------------- | -------------------------------- | ---------------------------------------- | ------------------------ | ------------------------------- | ------------------------------- |
| **Data model**        | Singleton tree + flat stream      | `TreeItem` tree (recursive `Vec`) | Flat `Vec<TreeLine>`             | Flat `Vec<TreeNode>`                     | `TreeNode` widget tree   | Recursive `Tree` renderable     | Circular linked nodes           |
| **Ownership**         | Singleton, shared refs            | User-owned, borrowed by widget    | Owned flat array                 | Owned flat array                         | Framework-owned          | User-owned                      | Container owns all nodes        |
| **State separation**  | Mixed (`open`/`expanded` on Node) | Clean (`TreeState` separate)      | No expand/collapse state         | `is_collapsed` on node                   | `_expanded` on node      | `expanded` on node              | No built-in state (data only)   |
| **Identification**    | Path string                       | Generic `Vec<Identifier>` path    | Array index + `parent_id`        | Row index (unstable)                     | `NodeID` (auto-int)      | None (render-only)              | Iterator position               |
| **Flatten algorithm** | `Tree:get()` + callback           | Free function `flatten()`         | BFS construction with scoring    | Forward scan skipping collapsed          | Lazy DFS in `_build()`   | Stack-based DFS render          | `depth_fullorder_iterator`      |
| **Expand/collapse**   | Mutable `open` + re-flatten       | `HashSet<Vec<Id>>` in `TreeState` | None (global depth limit)        | `is_collapsed` bool + height propagation | `_expanded` bool         | `expanded` bool                 | N/A (data container)            |
| **Filtering**         | Predicate on walk                 | User filters before passing       | During BFS construction (scored) | N/A                                      | CSS + filter             | N/A                             | Standard algorithm on iterators |
| **Virtual scroll**    | Picker list                       | `offset` + forward-scan           | Not needed (bounded array)       | Cursive framework handles                | `ScrollView` inheritance | N/A (renderable)                | N/A (data container)            |
| **Guide characters**  | Picker formatter                  | Node symbols only (▶/▼)          | Precomputed `left_branches`      | Symbols only (▸/▾/◦)                     | DFS-built guide path     | Four-state `levels` accumulator | N/A (data container)            |
| **Search/filter**     | `fd` + `keep_parents`             | N/A                               | Tree = f(pattern)                | N/A                                      | Built-in                 | N/A                             | N/A                             |
| **Cache locality**    | Poor (Lua tables)                 | Poor (recursive heap `Vec`)       | Excellent (flat `Vec`)           | Excellent (flat `Vec`)                   | Poor (object graph)      | Poor (recursive list)           | Poor (individual alloc)         |

### Key observations

**State separation is the clearest differentiator.** ratatui-tree-widget's `TreeState` is separate from `TreeItem` — you can have multiple states for the same tree (e.g., two views with different open sets). Snacks, Textual, and cursive_tree_view all mix expand/collapse state directly on nodes, meaning the tree can only have one visual state at a time. stlab::forest is purely a data container with no built-in visual state — the cleanest separation of all, but at the cost of providing no UI primitives.

**Flatten as a pure function vs. a method-with-side-effects.** ratatui's `flatten()` is a free function taking immutable data + state → flat list. Snacks' `Tree:get()` is a method on the singleton that lazily expands directories during traversal (a side effect). broot eliminates the question entirely by building the flat list directly — there is no tree-to-flat conversion because the tree _is_ flat. The pure function approach (ratatui) or direct flat construction (broot) are both more testable than the method-with-side-effects approach.

**Two approaches to flat storage.** cursive_tree_view and broot both store trees as flat arrays, but with different designs. cursive_tree_view uses `level` + sequential position with collapsed nodes remaining in the array (skipped during render). broot discards children entirely — the array contains only visible nodes, rebuilt from scratch on each keystroke. cursive_tree_view optimizes for dynamic expand/collapse; broot optimizes for search-driven exploration.

**Guide character rendering.** Rich's four-state model (SPACE, CONTINUE, FORK, END) with a per-depth `levels` accumulator is the most explicit algorithm. broot precomputes the equivalent information as `left_branches: Box<[bool]>` during construction, avoiding any per-render computation. Textual stores the full ancestor `path` list on each `_TreeLine` and derives guides at render time. ratatui-tree-widget uses only node symbols (▶/▼/spaces), not connecting lines — the simplest approach but least visually informative.

**Identification strategy.** ratatui's generic `Vec<Identifier>` is the most general. Textual's `NodeID` (auto-incrementing int with global lookup table) is efficient but framework-specific. cursive_tree_view's row-based identification is fragile across mutations. broot uses array indices which are unstable across rebuilds but this doesn't matter because the tree is rebuilt on every keystroke.

**Feature richness vs. architectural clarity.** Snacks has git integration, diagnostics propagation, file watching, search mode, and snapshot diffing — features a real file explorer needs. ratatui-tree-widget is minimal but architecturally clean. broot demonstrates that a radically different paradigm (tree-as-search-result) can be highly effective. A good design should achieve the clean separation of ratatui while being extensible enough to support both traditional expand/collapse and broot-style search-driven views.

---

## 6. Analysis Through Sean Parent's Principles

### Avoiding incidental data structures

> "An incidental data structure is a data structure where there is no object representing the structure as a whole." — [Data Structures][sean-parent-ds]

**Snacks' `Tree`** is an incidental data structure in Sean Parent's sense. The `parent` field on each `Node` is a direct Lua reference creating a doubly-linked tree. There is a "whole" object (`Tree`), but the `nodes` table (a path → node lookup) and the `parent` back-references create multiple overlapping ways to traverse the structure. Copying the tree would require deep-copying all nodes and re-wiring parent references — which Snacks doesn't support.

**ratatui-tree-widget's `TreeItem`** is closer to a proper tree — `children: Vec<Self>` with `#[derive(Clone)]` makes it a value type that can be copied. However, the recursive `Vec<Self>` still involves pointer chasing (each `Vec` is heap-allocated). For cache locality, a flat vector with parent/child indices would be better:

```d
// Flat storage (Sean Parent's preferred approach)
struct Tree(Identifier) {
    struct Node {
        Identifier id;
        string text;
        size_t parent;        // index into nodes[]
        size_t firstChild;    // index into nodes[]
        size_t nextSibling;   // index into nodes[]
    }
    Node[] nodes;
}
```

### Value semantics

> "Value semantics are the cleanest way to implement Whole-Part relationships." — [Value Semantics][sean-parent-vs]

**ratatui-tree-widget** achieves value semantics well. `TreeItem` derives `Clone`; the entire tree can be copied as a value. `TreeState` is also a regular type with `Default`. This enables easy testing (construct a tree, copy it, modify the copy, compare) and undo/redo (snapshot the tree before modification).

**Snacks' `Tree`** is a mutable singleton. It cannot be copied. The `snapshot()`/`changed()` methods are a workaround — they capture specific fields for comparison without actually copying the tree. This is a pragmatic solution for a Lua environment where deep copying is expensive, but it's not value semantics.

For D, the tree should be a regular copyable value. With flat storage (`Node[]`), copy is a single array duplication — no recursive traversal needed.

### Separate algorithms from data

> "Algorithms are more fundamental than the data structures on which they operate." — [Generic Programming][sean-parent-gp]

**ratatui-tree-widget's `flatten()`** is a free function taking data + state → flat list. This is the right pattern — the algorithm is separate from both the data model and the interaction state. It can be tested independently, reused with different state, and composed with other operations.

**Snacks' `Tree:walk()`/`Tree:get()`** are methods on the singleton. They conflate traversal with lazy expansion (a side effect) and filtering (a concern of the view layer). Separating these would mean: a pure traversal function, a separate expansion function, and filtering as a composable predicate.

For D, tree operations should be free functions with range interfaces. A `flatten` function should take a tree and an opened set and return a range of `Flattened(depth, nodeRef)` structs.

### Separate data from visual state

**ratatui-tree-widget** cleanly separates `TreeItem` (data) from `TreeState` (opened, selected, offset). The widget borrows both at render time. This means you can:

- Have multiple `TreeState` instances for the same data (e.g., two views).
- Serialize/deserialize `TreeState` independently.
- Test data operations without visual state.

**Snacks** mixes them: `open` (visual state) lives on `Node` alongside `path`/`type` (data). The `status` and `severity` fields are also decoration (from git and LSP) rather than intrinsic node data.

The ratatui pattern is the one to follow.

### Regular types

> "A type is regular if it behaves like int." — [Regular Types][sean-parent-rt]

**ratatui-tree-widget's Identifier constraint** (`Clone + PartialEq + Eq + Hash`) defines the minimum interface for a node identifier to be usable in sets and maps, comparable, and copyable. This maps directly to D's `opEquals` and `toHash`.

**Snacks nodes** are identity-based — two nodes are the "same" if they are the same Lua table (reference equality). Path strings serve as external identifiers but nodes themselves don't have value equality.

For D, node identifiers should be regular types satisfying the [Regular Types][sean-parent-rt] requirements.

### Sean Parent's own tree: stlab::forest

`stlab::forest` is Sean Parent's direct implementation of a tree container that avoids incidental data structures. It provides a single "whole" object with clear ownership, deep copy via traversal-based reconstruction, and a standard iterator interface.

However, `stlab::forest` uses individual heap-allocated nodes with pointer-based circular linking. This achieves O(1) structural modification and stable iterators but at the cost of cache locality. The flat-array approach recommended in [Section 7](#7-design-principles-for-sparkles-tree-view) reverses this tradeoff — better cache locality and `@nogc` friendliness, but O(n) insertion.

The key takeaway from `stlab::forest` is not its memory layout but its **traversal model**. The fullorder traversal (visiting each node twice — on leading and trailing edges) naturally supports `depth_fullorder_iterator`, which yields `(node, depth)` pairs in preorder. This is exactly what a tree renderer needs for indentation. A D implementation should provide an equivalent `depthFirst` range adaptor regardless of the underlying storage model.

The 2×2 link array (`_nodes[leading|trailing][prior|next]`) is an elegant encoding of tree relationships, but it is optimized for dynamic trees with frequent structural modification — a use case less relevant for tree _views_, which typically receive an already-built tree and focus on display and navigation.

---

## 7. Design Principles for Sparkles Tree-View

Synthesizing the findings from both case studies, cross-library patterns, and Sean Parent's principles:

### 1. Three-layer architecture

Follow ratatui's separation: `TreeItem` (data), `TreeState` (interaction), and `TreeRenderer` (visual output). Each layer has a single responsibility and no knowledge of the others' internals.

### 2. Flat storage with index-based relationships

Follow [Sean Parent's guidance on data structures][sean-parent-ds]: store all nodes in a contiguous `Node[]` array with parent/child/sibling indices rather than recursive pointer-based trees. This gives better cache locality than ratatui's recursive `Vec<Self>` and avoids the incidental structure of Snacks' parent references.

### 3. Separate data model from view state

Follow ratatui's pattern: the opened set, selection, and scroll position live in `TreeState`, not on nodes. This enables multiple views of the same tree data and clean serialization of view state.

### 4. Flatten as a free function

Follow ratatui's `flatten()` pattern: a pure free function `flatten(tree, state) → range of Flattened(depth, nodeRef)`. No side effects, no lazy expansion mixed in. Testable and composable.

### 5. Path-based identification

Follow both references: nodes are identified by a `Identifier[]` path from root. The `Identifier` type is generic with `opEquals`/`toHash` constraints, matching ratatui's `Clone + PartialEq + Eq + Hash` and Sean Parent's [Regular Types](../sean-parent/regular-types.md).

### 6. DbI for node capabilities

Follow the project's [Design by Introspection guidelines][dbi-guidelines]: use optional primitives for `hasChildren`, `hasIcon`, `hasStatus`, etc. A tree of file-system entries has different capabilities than a tree of AST nodes — DbI lets the renderer adapt without separate type hierarchies.

### 7. Output range rendering

Follow the project's [functional/declarative guidelines][functional-guidelines]: the tree renderer writes to any output range, not just stdout. This enables rendering to `SmallBuffer`, `appender!string`, or a terminal buffer.

### 8. Value semantics

Follow ratatui + [Sean Parent's value semantics][sean-parent-vs]: the entire tree is copyable. With flat storage, this is a single array copy. Enables snapshot-based testing, undo/redo, and the snapshot-diffing pattern Snacks demonstrates.

### 9. `@nogc` path

Follow the project guidelines: tree traversal and rendering should work with `SmallBuffer` and avoid GC allocation. The flat storage model (contiguous `Node[]`) is naturally `@nogc`-friendly — no recursive heap allocation needed during traversal.

### 10. Lazy children

Follow Snacks' pattern of separating user intent (`open`) from loaded state (`expanded`): children can be loaded on demand via a callback or range. The tree data model should support both eagerly-populated trees (for in-memory data) and lazily-populated trees (for filesystem or network sources).

### 11. Four-state guide character model

Follow Rich's rendering algorithm: a `levels` array tracks the guide state (SPACE, CONTINUE, FORK, END) at each depth. For each visible node, the prefix is built by concatenating `levels[0..depth]`, then updating `levels[depth]` based on whether the node is the last child. broot's precomputed `left_branches: Box<[bool]>` demonstrates that this can be computed once during flatten rather than per-render, which is more efficient for static or infrequently-changing trees.

### 12. Depth-first range adaptor

Follow stlab::forest's `depth_fullorder_iterator` pattern: provide a `depthFirst` range adaptor that yields `(depth, nodeRef, isLastChild)` tuples. This gives the renderer everything it needs for guide characters and indentation in a single traversal. The `isLastChild` field enables Rich's four-state algorithm without requiring backward lookups.

### 13. Tree-as-search-result paradigm

broot demonstrates that a tree view does not require persistent expand/collapse state. An alternative mode where the visible tree is rebuilt as a function of `(data_source, search_pattern, depth_limit)` can coexist with traditional expand/collapse. The tree data model should be cheap enough to construct that rebuilding per-keystroke is viable — flat storage with precomputed guide state makes this feasible.

---

## References

[tui-index]: index.md
[comparison]: comparison.md
[broot]: broot.md
[cursive]: cursive.md
[textual]: textual.md
[brick]: brick.md
[bubbletea]: bubbletea.md
[tview]: tview.md
[ftxui]: ftxui.md
[nottui]: nottui.md
[imtui]: imtui.md
[sean-parent-index]: ../sean-parent/index.md
[sean-parent-ds]: ../sean-parent/data-structures.md
[sean-parent-vs]: ../sean-parent/value-semantics.md
[sean-parent-rt]: ../sean-parent/regular-types.md
[sean-parent-gp]: ../sean-parent/generic-programming.md
[dbi-guidelines]: ../../guidelines/design-by-introspection-01-guidelines.md
[functional-guidelines]: ../../guidelines/functional-declarative-programming-guidelines.md

## Rust Crate References

[ratatui-tree-widget-state]: https://github.com/ratatui/ratatui-widgets/tree/main/ratatui-tree-widget
[cursive-tree-view]: https://docs.rs/cursive_tree_view/latest/cursive_tree_view/
[stlab-forest]: https://github.com/stlab/libraries/blob/main/include/stlab/forest.hpp
[broot-tree-line]: https://docs.rs/broot/latest/broot/tree/struct.TreeLine.html
[broot-dam]: https://docs.rs/broot/latest/broot/task_sync/struct.Dam.html
