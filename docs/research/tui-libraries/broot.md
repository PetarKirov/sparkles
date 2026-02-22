# Broot (Rust)

A terminal tree navigator and file manager that treats the entire directory tree as a searchable, filterable entity. Its key innovation is the "tree as search result" paradigm: instead of navigating a dumb expand/collapse hierarchy, users type a fuzzy pattern and the tree reshapes itself to show only matching paths, with all necessary ancestor directories kept visible for context.

| Field      | Value                                                        |
| ---------- | ------------------------------------------------------------ |
| Language   | Rust                                                         |
| Repository | <https://github.com/Canop/broot>                             |
| License    | MIT                                                          |
| Author     | Denys Seguret (Canop)                                        |
| Paradigm   | Flat-array tree with BFS construction, score-based filtering |

---

## Overview

Broot is not a TUI framework -- it is a standalone terminal application. However, its internal architecture for representing, building, filtering, and rendering file trees is one of the most sophisticated in any terminal tool. It is studied here because it solves the exact problem Sparkles' tree view needs to address: displaying a potentially huge tree in a terminal viewport with real-time fuzzy filtering.

The central architectural decision is a **flat array of lines** (`Vec<TreeLine>`) rather than a recursive tree structure. The tree is _rebuilt from the filesystem_ on every filter change, using a BFS traversal that scores, prunes, and flattens in a single pass. This eliminates the complexity of maintaining parent-child pointers, simplifies scrolling to array indexing, and makes the filtered tree a first-class data structure rather than a view over a hidden full tree.

---

## Architecture Overview

```
                                 +------------------+
  User Input (pattern) -------->| TreeBuilder (BFS) |
                                 +------------------+
                                        |
                      constructs BLines (intermediate arena)
                                        |
                                        v
                                 +------------------+
                                 |   Vec<TreeLine>   |  <-- flat array
                                 +------------------+
                                        |
                          scroll offset + viewport height
                                        |
                                        v
                                 +------------------+
                                 | DisplayableTree  |  <-- renders to terminal
                                 +------------------+
```

The architecture has three layers:

1. **TreeBuilder** -- BFS traversal that reads the filesystem, applies pattern matching, scores candidates, and produces a flat `Vec<TreeLine>`.
2. **Tree** -- owns the flat line array plus viewport state (scroll offset, selection index). Provides navigation, refresh, and selection management.
3. **DisplayableTree** -- renders the visible portion of the flat array to the terminal, drawing branch connectors, highlighting matches, and showing a scrollbar.

### Dual-Tree State in BrowserState

The `BrowserState` (the main application state) maintains **two trees**:

- **`tree`** -- the base (unfiltered) tree.
- **`filtered_tree`** -- an optional second tree built when a search pattern is active.

The `displayed_tree()` accessor returns `filtered_tree` when present, `tree` otherwise. This means filtering does not mutate the base tree; instead, a fresh tree is built from the filesystem with the pattern applied. Clearing the filter discards the filtered tree and returns to the base tree.

---

## Data Model

### TreeLine -- The Flat Node

Each line in the flat array is a `TreeLine`:

```rust
struct TreeLine {
    // --- Identity ---
    id: TreeLineId,                     // unique ID (usize)
    parent_id: Option<TreeLineId>,      // parent reference
    depth: u16,                         // nesting level

    // --- Path ---
    path: PathBuf,                      // full filesystem path
    subpath: String,                    // relative displayable path
    name: String,                       // display name (chars may be stripped)

    // --- Classification ---
    line_type: TreeLineType,            // File | Dir | SymLink | BrokenSymLink | Pruning
    icon: Option<char>,                 // optional icon character

    // --- Filtering & Scoring ---
    score: i32,                         // 0 if no pattern active
    direct_match: bool,                 // whether this line directly matched
    has_error: bool,                    // access/read error

    // --- Hierarchy ---
    nb_kept_children: usize,            // filtered child count
    unlisted: usize,                    // hidden children (Dir) or siblings (Pruning)

    // --- Rendering ---
    left_branches: Box<[bool]>,         // depth-sized array for tree connector drawing

    // --- Extended Data ---
    metadata: fs::Metadata,             // filesystem attributes
    sum: Option<FileSum>,               // size aggregation (lazy)
    git_status: Option<LineGitStatus>,  // version control status
}
```

Key design points:

- **No child pointers.** The only structural link is `parent_id`. Children are determined by sequential position in the flat array combined with depth values.
- **`left_branches`** is a precomputed rendering hint: for each depth level, it records whether a vertical branch connector should be drawn (i.e., whether an ancestor at that depth has more siblings below).
- **`unlisted`** supports the `Pruning` pseudo-line: a synthetic line that says "N more items not shown", collapsing invisible children into a count.
- **`score`** is 0 when there is no active pattern, and positive when the line matched. Higher scores indicate better matches.

### TreeLineType

```rust
enum TreeLineType {
    File,
    Dir,
    SymLink { direct_target: String, final_is_dir: bool, final_target: PathBuf },
    BrokenSymLink(String),
    Pruning,        // synthetic "N unlisted" collapse marker
}
```

The `Pruning` variant is architecturally significant. It is not a real filesystem entry -- it is a placeholder inserted during tree construction to represent children that were excluded by scoring or capacity limits. This keeps the user informed about what was pruned without wasting screen space.

### TreeOptions -- Configuration

```rust
struct TreeOptions {
    // Display
    show_hidden: bool,
    show_counts: bool,
    show_dates: bool,
    show_sizes: bool,
    show_permissions: bool,
    show_tree: bool,                    // tree vs flat listing
    show_git_file_info: bool,
    show_selection_mark: bool,
    show_device_id: bool,
    show_root_fs: bool,

    // Filtering
    only_folders: bool,
    respect_git_ignore: bool,
    filter_by_git_status: bool,
    pattern: InputPattern,              // active search pattern
    trim_root: bool,                    // cut out direct children of root

    // Structure
    max_depth: Option<u16>,             // recursion limit
    sort: Sort,                         // sorting strategy
    cols_order: ColsOrder,              // column display order
    date_time_format: String,
}
```

### Sort and Deep Display

```rust
enum Sort {
    None,               // alphabetical, multi-level allowed
    Count,              // by item count, single-level only
    Date,               // by modification date, single-level only
    Size,               // by file/directory size, single-level only
    TypeDirsFirst,      // directories before files, multi-level allowed
    TypeDirsLast,       // files before directories, multi-level allowed
}
```

A critical design insight: **quantitative sorts (Count, Date, Size) flatten the tree to a single level.** The `prevent_deep_display()` method returns `true` for these sorts, because comparing sizes or dates across different nesting depths is meaningless. Only `None`, `TypeDirsFirst`, and `TypeDirsLast` preserve hierarchical display.

---

## Tree Building -- The BFS Algorithm

Tree construction is the core of broot's architecture. It is handled by `TreeBuilder`, which performs a **breadth-first search** of the filesystem, scoring candidates against the active pattern, and producing a flat `Vec<TreeLine>`.

### Intermediate Representation: BLine

During construction, the builder works with `BLine` objects stored in an arena (`id_arena`):

```rust
struct BLine {
    parent_id: Option<BId>,
    path: PathBuf,
    depth: u16,
    file_type: fs::FileType,

    // Build state
    children: Vec<BId>,                 // sorted, filtered child references
    next_child_idx: usize,              // iteration cursor

    // Filtering
    has_match: bool,                    // matches pattern
    direct_match: bool,                 // directly matched (vs ancestor match)
    score: i32,                         // match quality score
    nb_kept_children: usize,            // surviving children after trim

    // Context
    has_error: bool,
    git_ignore_chain: GitIgnoreChain,
    special_handling: SpecialHandling,
}
```

`BLine` differs from `TreeLine` in two ways:

1. It has **child pointers** (`children: Vec<BId>`) because the builder needs to traverse the hierarchy.
2. It stores **build-time state** (`next_child_idx`, `git_ignore_chain`) that is discarded after construction.

### The Build Algorithm

The `gather_lines` method implements BFS with early termination:

```
1. Initialize: push root directory into open_dirs queue
2. While open_dirs is not empty:
   a. Pop a directory from open_dirs
   b. Read its entries via fs::read_dir
   c. For each entry:
      - Apply filters: hidden files, git-ignore, type (only_folders), symlink validation
      - If pattern is active: compute score = pattern.score_of(candidate)
      - If score > 0 or entry is a directory (kept for hierarchy): create BLine
      - If entry is a directory: add to next_level_dirs
   d. When current level is exhausted ("this depth is finished, we must go deeper"):
      - Move next_level_dirs into open_dirs
3. Stop when enough lines are gathered to fill the screen
```

### Early Termination Strategy

Broot does **not** read the entire filesystem. It stops when it has enough lines:

- **Without a pattern**: stops at `targeted_size` lines (approximately the screen height).
- **With a pattern**: gathers `10 * targeted_size` lines before stopping, to allow better ranking among candidates.

The `Dam` parameter enables **cancellation**: when the user types a new character, the current build is interrupted and a new build starts. This provides responsive real-time filtering even on large trees.

### Depth Limits

Enforced during BFS: `if self.options.max_depth.map_or(false, |max| child.depth > max)` -- children beyond the maximum depth are skipped entirely.

### Scoring Formula

During BFS, each candidate receives a score:

```
base_score = 10000 - depth
if pattern matches:
    score += pattern_score + 10
    direct_match = true
```

Depth penalty ensures that shallower matches rank higher. The pattern score comes from the fuzzy matcher (see below). The `+10` bonus distinguishes direct matches from ancestor-only matches.

### Trimming with SortableBId

When more lines are gathered than can be displayed, `trim_excess` uses a **min-heap** of `SortableBId`:

```rust
struct SortableBId {
    id: BId,
    score: i32,
}

// Ord is INVERTED: lowest score at heap top
impl Ord for SortableBId {
    fn cmp(&self, other: &Self) -> Ordering {
        other.score.cmp(&self.score)  // reversed!
    }
}
```

The min-heap keeps the lowest-scoring nodes at the top. When the heap exceeds capacity, the lowest-scoring node is popped and discarded. This ensures the final tree contains the highest-scoring matches.

### Conversion: BLine to TreeLine

The `take_as_tree` method iterates the arena, converting surviving `BLine` entries into `TreeLine` objects:

1. Only BLines with `has_match == true` (or necessary ancestors) are included.
2. `left_branches` is computed by scanning ancestor chain.
3. Pruning lines are inserted for directories with `unlisted > 0`.
4. The result is `Vec<TreeLine>` -- the flat array owned by `Tree`.

---

## Pattern System -- Fuzzy Search

Broot's pattern system is its defining feature. It supports multiple match modes composed with boolean operators.

### Pattern Types

| Type                  | Description                         |
| --------------------- | ----------------------------------- |
| `FuzzyPattern`        | Subsequence match with scoring      |
| `ExactPattern`        | Literal substring match             |
| `RegexPattern`        | Regular expression match            |
| `ContentExactPattern` | Search inside file contents (exact) |
| `ContentRegexPattern` | Search inside file contents (regex) |
| `CompositePattern`    | Boolean combination of patterns     |

### Fuzzy Matching Algorithm

The `FuzzyPattern` implements subsequence matching with a sophisticated scoring system:

**Match definition**: All pattern characters must appear in order in the candidate string, but need not be consecutive. Gaps ("holes") between matched characters are allowed but penalized.

**Scoring constants**:

| Constant           | Value    | Description                               |
| ------------------ | -------- | ----------------------------------------- |
| `BONUS_MATCH`      | 50,000   | Base bonus for any match                  |
| `BONUS_EXACT`      | 1,000    | Exact length match (pattern == candidate) |
| `BONUS_START`      | 10       | Pattern starts at position 0              |
| `BONUS_START_WORD` | 5        | Pattern starts after `_`, ` `, `-`        |
| Candidate length   | -1/char  | Penalty for long candidates               |
| Match span         | -10/char | Penalty for spread-out matches            |
| Holes              | -30/hole | Penalty for gaps between matches          |
| Isolated chars     | -15/char | Penalty for single matched chars          |

**Unicode and case handling**: Input is normalized through `secular::lower_lay_char`, providing case-insensitive and diacritic-insensitive matching. This allows "reveille" to match "REVEILLE" and handles Cyrillic case variants.

**Tight match optimization**: The `tight_match_from_index` function finds the subsequence match with the smallest span. It limits holes based on pattern length (e.g., a 4-character pattern allows at most 2 holes).

**Multi-match selection**: When multiple valid matches exist, the algorithm selects the one with the highest score. A perfect match (exact length + word boundary start) returns immediately without further searching.

### Composite Patterns (Boolean Operators)

`CompositePattern` uses a `BeTree<PatternOperator, Pattern>` expression tree:

- **AND**: Both operands must match. Scores are summed. Short-circuits on `None`.
- **OR**: Either operand suffices. Scores are summed if both match.
- **NOT**: Inverts matching. Returns score 1 if the pattern does NOT match, `None` if it does.

This allows queries like: fuzzy match on name AND exact match on extension AND NOT matching a gitignore pattern.

### Pattern Interaction with Tree Building

The pattern is evaluated during BFS, not after. This is critical for performance:

1. During `gather_lines`, each filesystem entry is scored against the active pattern.
2. Entries with `score == 0` (no match) are still included if they are directories -- because their children might match.
3. After BFS completes, directories whose subtrees produced no matches are pruned.
4. The remaining lines are sorted by score for display.

This means the tree is **built filtered**. There is no separate "filter" pass over a pre-built tree. The tree structure itself is shaped by the search pattern.

---

## Tree State and Expand/Collapse

### No Traditional Expand/Collapse

Broot does not have a traditional expand/collapse model. Instead:

- **With no pattern**: the tree is displayed to the depth that fits the screen, with `Pruning` lines showing where content was truncated.
- **With a pattern**: the tree reshapes to show only matching paths and their ancestors. Deeper directories are automatically "expanded" if they contain matches.
- **Explicit depth control**: users can increase or decrease `max_depth` to see more or fewer levels.

### Pruning Lines

When a directory has children that are not shown (either due to screen space limits or filtering), a `Pruning` line is inserted:

```
├── src/
│   ├── main.rs
│   └── 47 unlisted
```

The `unlisted` count on the Pruning line tells the user how many entries are hidden. This replaces the expand/collapse toggle found in traditional tree widgets.

### Selection State

Selection is stored as a simple index into the flat array:

```rust
struct Tree {
    selection: usize,   // index into self.lines
    // ...
}
```

Navigation methods (`move_selection`, `try_select_path`, `try_select_first`, etc.) manipulate this index. The Pruning lines are **not selectable** -- `is_selectable()` returns false for them, so navigation skips over them.

### State Preservation Across Rebuilds

When the tree is rebuilt (due to filter change, refresh, or navigation), broot attempts to preserve the user's context:

- `try_select_path()` searches the new tree for the previously selected path.
- `try_select_best_match()` selects the highest-scoring match in the new tree.
- `make_selection_visible()` adjusts scroll to keep selection in viewport.

---

## Scrolling and Viewport

### Scroll Model

Scrolling is handled by a simple offset into the flat array:

```rust
struct Tree {
    scroll: usize,     // number of hidden lines above viewport
    // ...
}
```

The `DisplayableTree` renderer iterates from `scroll` to `scroll + viewport_height`, drawing one `TreeLine` per terminal row.

### Rendering Loop

```rust
for y in 1..self.area.height {
    let mut line_index = y as usize;
    if line_index > 0 {
        line_index += tree.scroll;
    }
    // render tree.lines[line_index]
}
```

This is not virtual scrolling in the sense of lazy loading -- all lines exist in memory. But since broot's BFS stops early (at `targeted_size`), the total line count is bounded to roughly the screen height (or 10x screen height when filtering). The flat array is small enough that no virtualization is needed.

### Scrollbar

When `in_app` mode is active, `termimad::compute_scrollbar()` calculates the thumb position based on `scroll`, `total_lines`, and `viewport_height`. The scrollbar thumb character `"▐"` is drawn at the rightmost column.

### Selection-Driven Scrolling

`make_selection_visible()` adjusts `scroll` to ensure the selected line is within the viewport. Navigation methods call this automatically after changing selection.

---

## Branch Connector Drawing

The `left_branches: Box<[bool]>` field on each `TreeLine` is a depth-sized boolean array. For each depth level, it records whether a vertical branch connector (`│`) should be drawn at that column.

This is computed during `after_lines_changed()` by scanning the flat array:

1. For each line, walk up the ancestor chain.
2. At each depth, check if the ancestor has more siblings below it in the flat array.
3. If yes, `left_branches[depth] = true` (draw `│`); if no, `left_branches[depth] = false` (draw space).

The renderer uses this to draw the tree structure:

```
├── src/          left_branches = [true]
│   ├── main.rs   left_branches = [true, true]
│   └── lib.rs    left_branches = [true, false]
└── Cargo.toml    left_branches = [false]
```

Unicode box-drawing characters:

- `├──` -- entry with siblings below
- `└──` -- last entry at this depth
- `│  ` -- vertical connector for ancestor with siblings below

---

## Git Integration

Git status is computed asynchronously (`ComputationResult<TreeGitStatus>`) and stored at the tree level. Individual lines carry `Option<LineGitStatus>` for per-file status display.

The `filter_by_git_status` option narrows the tree to only files with non-null git status (modified, staged, etc.), turning broot into a git-aware file selector.

---

## Column-Based Rendering

The `DisplayableTree` renderer processes columns in a configurable order:

| Column     | Content                        |
| ---------- | ------------------------------ |
| Mark       | Selection indicator            |
| Git        | Git status character           |
| Branch     | Tree connectors                |
| DeviceId   | Filesystem device              |
| Permission | Unix rwx permissions           |
| Date       | Modification timestamp         |
| Size       | File/directory size            |
| Count      | Item count                     |
| Name       | Filename with match highlights |

The `visible_cols` vector is filtered based on `TreeOptions` (e.g., `show_sizes`, `show_dates`). Each column's `void_len` determines spacing between columns.

Match highlighting is applied during Name column rendering:

1. The path is split into parent directory and filename components.
2. `char_match_style` is applied to characters that matched the fuzzy pattern.
3. Long paths are truncated with ellipsis.

---

## Build Report

After tree construction, `BuildReport` records filtering statistics:

```rust
struct BuildReport {
    gitignored_count: usize,    // files excluded by .gitignore
    hidden_count: usize,        // files excluded as hidden (dot-prefix)
    error_count: usize,         // files excluded due to access errors
}
```

Each file is counted in at most one category. This allows broot to display a summary like "12 gitignored, 3 hidden" in the status bar.

---

## Key Architectural Insights

### 1. Flat Array Over Recursive Tree

Broot's most important design decision is representing the tree as `Vec<TreeLine>` rather than a recursive structure. This provides:

- **O(1) selection by index**: no tree traversal needed.
- **Trivial scrolling**: viewport is a slice of the array.
- **Simple rendering**: iterate the array, draw one line per row.
- **No pointer management**: parent linkage is optional metadata, not a structural requirement.

The cost is that tree operations like "find all children of node X" require a linear scan. But since the array is small (bounded to ~screen height), this is fast in practice.

### 2. Tree as Search Result

Traditional tree views have a fixed structure that users navigate with expand/collapse. Broot inverts this: the tree structure is a **function of the search pattern**. Each keystroke triggers a fresh BFS that produces a new flat array showing only relevant paths.

This eliminates the "lost in deep hierarchy" problem. Users never need to manually expand directories to find a file -- they type part of its name and the tree reshapes to show it.

### 3. Build-Time Filtering

Filtering happens during tree construction, not as a post-processing step. The BFS skips non-matching entries (except directories needed for hierarchy), scores matches, and trims excess lines -- all in one pass. This is more efficient than building a full tree and then filtering it.

### 4. Pruning as First-Class Concept

The `Pruning` line type is a smart design. Rather than silently hiding content, broot shows how much was hidden. This keeps the user informed and provides a visual cue that more content exists. The Pruning line is not selectable, so it doesn't interfere with navigation.

### 5. Dual-Tree State

Keeping the base tree and filtered tree as separate objects avoids mutation and makes it trivial to restore the unfiltered view. The `displayed_tree()` accessor abstracts this behind a simple API.

### 6. Early Termination with Score-Based Ranking

BFS stops when enough lines are gathered, and excess lines are pruned via a min-heap. This ensures:

- Bounded memory usage regardless of filesystem size.
- Bounded build time regardless of directory depth.
- Best matches are kept (highest-scoring lines survive the heap).

### 7. Cancellable Builds

The `Dam` parameter allows builds to be interrupted when the user types a new character. This provides responsive real-time filtering: each keystroke cancels the previous build and starts a new one.

---

## Relevance for Sparkles

### Directly Applicable Patterns

- **Flat array representation**: The `Vec<TreeLine>` model maps directly to a D `TreeLine[]` or `SmallBuffer!(TreeLine, N)`. This is the simplest correct representation for a scrollable, selectable tree view.

- **Build-time filtering**: Rather than building a full tree and hiding non-matching nodes, build a filtered tree from scratch. This avoids the complexity of maintaining visibility state and parent-chain invariants.

- **Pruning lines**: Inserting synthetic "N unlisted" lines is a user-friendly way to handle truncation. Sparkles should adopt this pattern.

- **Score-based ranking**: The `10000 - depth + pattern_score` formula is a simple but effective way to rank matches. Shallower results are preferred, with pattern quality as a tiebreaker.

- **Precomputed branch connectors**: The `left_branches` array per line eliminates the need to look up ancestors during rendering. This is especially valuable in `@nogc` D code where dynamic lookups are constrained.

### Design Differences to Consider

- **Broot rebuilds from filesystem on every keystroke.** For Sparkles, the data source may not be the filesystem, and rebuilding from scratch may not be appropriate. A persistent tree with incremental filtering may be needed.

- **Broot's flat array is ephemeral.** It is rebuilt frequently and never persisted. Sparkles may need a stable tree identity across rebuilds (e.g., for animation or state preservation).

- **Broot has no expand/collapse toggle.** Users control depth via max_depth, not per-node toggles. A Sparkles tree view may need both: broot-style pattern filtering AND traditional per-node expand/collapse for manual exploration.

### Key Takeaway

Broot demonstrates that a tree view does not need to be a tree data structure. A flat array with depth annotations, parent references, and precomputed rendering hints is simpler, faster, and more flexible. The "tree as search result" paradigm -- where the tree structure is a function of the active filter -- is a powerful alternative to traditional expand/collapse navigation.

---

## See Also

- [Tree-View Case Study][tree-view-case-study] — Comparative analysis of tree implementations across 13 libraries
- [Ratatui][ratatui] — Rust TUI with a clean tree-widget architecture
- [Comparison][comparison] — Cross-library design synthesis

[tree-view-case-study]: tree-view-case-study.md
[ratatui]: ratatui.md
[comparison]: comparison.md

---

## Markdown References

[broot-tree-line]: https://docs.rs/broot/latest/broot/tree/struct.TreeLine.html
[broot-tree-builder]: https://docs.rs/broot/latest/broot/tree/struct.TreeBuilder.html
[broot-dam]: https://docs.rs/broot/latest/broot/task_sync/struct.Dam.html
