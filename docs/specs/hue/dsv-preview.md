# `hue` DSV preview — Feature Requirements (the data browser)

_**Status:** design · **Date:** 2026-08-18 · **Scope:** Delimiter-Separated
Values (CSV, TSV, PSV, semicolon-CSV, …) as a hue **content kind**: the grid
preview across all four sinks, the dialect sniffer, the interactive
**data-browser** tier (multi-key sort, filtering, column hide/reorder), the
selection/copy deltas, and the `sparkles:dsv` engine underneath._

> [!NOTE]
> Phase 1 is underway: the **D0 engine shipped** (`3f254420` —
> `libs/dsv`, the `DSD`/`DSM` engine-side rows below). Everything else is
> forward-looking design. Status legend and ID conventions: see the
> [overview](./index.md).

## Design & scope

### What it is

A `.csv` (or `.tsv`, `.psv`, sniffed `.txt`/stdin) target renders as a
**decorated data grid** by default in **every** sink — the
[`MOD8`](./feature-requirements.md) doctrine applied to a third document
family: GUI, TUI, non-interactive ANSI, and HTML all paint the same grid from
the same model, and `--raw` ([`CLI9`](./feature-requirements.md)) reverts to
highlighted source. Interactively the grid is a **data browser**: a pinned
header, a row-number gutter, multi-key sorting, a filter bar plus header
menus, and column hide/reorder — a viewer in the VisiData/csvlens tradition,
not an editor.

Almost everything visual already exists. The box-drawn grid is
[`MDP10`](./gui.md)'s table (`resolveTracks`, bold header + heavy `┝━┿━┥`
rule, per-column alignment); the selection regime is
[`TBL1`–`TBL6`](./gui.md) unchanged; the wide-content scroll idiom is
[`COD6`](./gui.md)'s border scrollbars; the filter bar follows the picker's
query-language doctrine ([`PKQ`](./picker.md)). What is genuinely new is the
**engine** (dialect sniffing, an RFC 4180 parser with an identity channel, a
record index, projection compute) and the **browser state machine** over it.

### Why the engine is a library (`sparkles:dsv`)

The same reasoning as [`sparkles:diff`](./diff-view.md) and `sparkles:fuzzy`:
hue's engines are things this repository owns, unit-tests, and benchmarks.
`sparkles:dsv` (`libs/dsv`) is the allocation-conscious compute core — dialect
detection, parsing, the record index, typed columns, and sort/filter
execution — `@safe pure nothrow @nogc` throughout, texts borrowed as spans,
storage in caller-owned `SmallBuffer` arenas, errors as `Expected`.
**`sparkles:base` is its only dependency**: the fuzzy full-text remainder
([`DSF3`](#filtering-dsf)) is matched by `sparkles:fuzzy` and combined by the
_host_, so neither engine depends on the other. hue owns the state machine,
chrome, keymap, and job scheduling.

### Reference points

| Borrowed                                     | From                                    |
| -------------------------------------------- | --------------------------------------- |
| the viewer-not-editor data-browser shape     | VisiData, csvlens                       |
| dialect sniffing by field-count consistency  | Python `csv.Sniffer` (design, not code) |
| quoting/parsing baseline                     | RFC 4180 (+ the real-world deviations)  |
| typed columns driving alignment & comparison | xsv/qsv, VisiData                       |
| per-column rainbow tint (raw view, deferred) | Rainbow CSV                             |
| cell-level CSV diff (deferred)               | daff                                    |

### Sequencing constraint: the table-rendering unification

A parallel effort (separate worktree) is unifying hue's md table rendering
pipeline with `sparkles.ui.components.table` (`libs/ui/.../components/table/` —
`grid.d`/`render.d`). To keep the two streams mergeable, this plan ships in two
phases: **phase 1** (D0/D1) builds the engine and a basic preview that flows
through the **existing** md table rendering path exactly as `viewMarkdown`'s
table case consumes it — touching nothing under `sparkles.ui.components.table`
— and then a **re-orientation checkpoint** (CHK) rebases onto the unified
pipeline and re-plans everything after it. Requirement rows below that need
table capabilities the current path lacks are marked **post-CHK**; the
milestone table is normative only up to CHK.

### Non-goals

- **Editing.** hue is a viewer; the bounded write surfaces belong to the diff
  spec ([`DST5`](./diff-view.md)). A projection (sort/filter/hide) never
  writes back.
- **Multi-sheet workbooks** (`.xlsx`, ODS) — a different acquisition problem.
- **A query engine.** The filter bar filters rows; it is not SQL, joins, or
  aggregation.

## Content kind & dispatch (`DSK`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                        | Status      | Traces to                                    |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ----------- | -------------------------------------------- |
| DSK1 | DSV must be a **content kind** like code/markdown/twoslash/diff (the dispatch-collapse doctrine, [`MOD8`/`MOD9`](./feature-requirements.md)): detected once by `DocumentPipeline.load`, dispatched through the same backend pick, rendered by every sink — no new modes.                                                                                           | not started | `document.d` `ContentKind.dsv`               |
| DSK2 | Detection: the extensions `.csv`, `.tsv`, `.psv` (and `.ssv`) must select the kind and **seed** the dialect (`DSD1`); a `.txt`/extensionless/stdin source must be **content-sniffed** (`DSD5`); `--dsv` must force the kind (a detection input, like `--markdown`), and `--raw` must force highlighted source in every sink ([`CLI9`](./feature-requirements.md)). | not started | `document.d` kind detection; `CliParams.dsv` |
| DSK3 | A DSV document must render the **grid preview by default in every sink** — GUI, TUI, ANSI, HTML — from one shared model and one widget view (`viewDsv`), the exact shape of `MOD8`'s markdown rule.                                                                                                                                                                | not started | `viewDsv` dispatched by all four sinks       |
| DSK4 | `--raw` on a DSV file renders highlighted source like any text file; without a bundled DSV grammar it degrades to plain text per [`DEG2`](./feature-requirements.md). Rainbow per-column raw styling is deferred (`DSZ2`).                                                                                                                                         | not started | the existing raw path                        |
| DSK5 | The **status chrome** must name the resolved dialect (delimiter · quote · header on/off), the row counts (visible/total when projected), the projection state (sort keys, active filter, hidden-column count), and the copy mode ([`SEL7`](./gui.md) doctrine).                                                                                                    | not started | status-bar segments; `DSB4`                  |

## Dialect detection (`DSD`)

Precedence: **flags > sniff > extension seed**. All sniffing reads a bounded
**sample** — the first 100 records or 256 KiB, whichever ends first
(provisional; one constant, shared with width measurement `DSN3`).

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                 | Status                                                                        | Traces to                                                  |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------- | ---------------------------------------------------------- |
| DSD1 | The extension must seed the delimiter (`.csv` → `,` · `.tsv` → tab · `.psv` → `\|` · `.ssv` → `;`), and a **consistency sniff** over the sample may override it within the candidate set `{, ; \t \|}`: the winning delimiter maximizes field-count consistency across sample records (quote-aware), ties broken by the seed, then by set order. This is what catches the semicolon CSVs European Excel writes into `.csv`. | partial (`3f254420`) — the engine ships; hue wiring is D1                     | `seedForExtension`; `sparkles.dsv.dialect.sniff`           |
| DSD2 | The quote character must be sniffed from `{" '}` — `"` unless `'` pairs consistently and `"` does not; RFC 4180 doubled-quote escaping (`""`) applies to whichever wins. `--dsv-quote` forces it.                                                                                                                                                                                                                           | partial (`3f254420`) — the sniff ships; `--dsv-quote` is D1                   | `sniff` quote evidence                                     |
| DSD3 | Header presence must be decided by heuristic under `--dsv-header=auto` (default): the first record is a header when its **type profile** differs from the body (body columns typed numeric/date while the first row is not) or when it is all-unique, non-numeric names; `yes`/`no` force it. A headerless file gets synthetic `A B C…` column names (display-only, never serialized into a copy).                          | partial (`3f254420`) — the heuristic ships; the flag + synthetic names are D1 | `detectHeader`                                             |
| DSD4 | `--dsv-delimiter=<char>`, `--dsv-quote=<char>`, `--dsv-header=auto\|yes\|no` must force any sniffed decision; a forced delimiter outside the candidate set is accepted verbatim (sniffing then only decides quote/header). All three are runtime-visible in the status chrome (`DSK5`).                                                                                                                                     | not started                                                                   | `CliParams.dsv*`                                           |
| DSD5 | **Content detection** for `.txt`/extensionless/stdin: the source is DSV when the sniff finds ≥ 2 columns at ≥ 90% field-count consistency over ≥ 3 sample records (provisional thresholds); otherwise it stays plain text. This is a bounded first step toward [`DEF6`](./feature-requirements.md) content-based detection, and the seam it should later flow through.                                                      | partial (`3f254420`) — the acceptance signal ships; hue wiring is D1          | `SniffResult.looksDsv`; `DSK2`                             |
| DSD6 | Encoding: UTF-8 with an optional BOM (stripped before parsing, preserved by whole-document copy `DSC4`); records end at CRLF or LF (mixed accepted, each record remembers its own terminator for `DSC4`); malformed UTF-8 bytes display as replacement glyphs but round-trip exactly through copy (the raw span is authoritative).                                                                                          | partial (`3f254420`) — the parse side ships; the copy consumers are `DSC4`    | `parseDsv` (BOM, per-record `Terminator`, lone-CR literal) |

## Model & parser — `sparkles:dsv` (`DSM`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                                                         | Status                                                                                               | Traces to                                                         |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------- |
| DSM1 | Parsing must implement RFC 4180 quoting — quoted fields, embedded delimiters, **embedded newlines**, doubled-quote escapes — plus the tolerated deviations: unquoted quotes mid-field are literal, a quote after field content re-enters quoted mode (Excel behavior), a final record without a terminator is a record.                                                                             | full (`3f254420`)                                                                                    | `sparkles.dsv.parse.parseDsv`                                     |
| DSM2 | Every cell must carry an **identity channel**: its half-open **raw byte span** in the borrowed source (quotes and escapes included) alongside its decoded text — the [`SEL1`](./gui.md) discipline — so sub-cell selection, char-precise crossing (`DSC3`), and whole-document reproduction (`DSC4`) stay honest. Decoding is lazy/windowed; the model never copies the file.                       | full (`3f254420`)                                                                                    | `DsvCell.raw`; `decodeCell` (simple cells borrow)                 |
| DSM3 | **Ragged rows must degrade, never error**: a short record renders padded missing cells (distinct `missing` styling), a long record grows the grid to the maximum field count (overflow columns named `…+1`), and the row is marked ragged; the status chrome counts ragged rows. An empty file or header-only file renders an empty grid plus a note ([`DEG`](./feature-requirements.md) doctrine). | partial (`3f254420`) — accounting + tolerant parse ship; the rendered half is D1                     | `DsvDoc.raggedCount`/`modalColumnCount`; grid `missing` slot (D1) |
| DSM4 | Each column must carry an inferred **type** from the sample: `int` · `float` · `date` (ISO 8601) · `bool` · `string`, with empty cells excluded from inference; a column types as the most specific type ≥ 95% of sampled non-empty cells satisfy (provisional). Types drive alignment (`DSG3`), sort comparison (`DSS2`), and filter operators (`DSF2`) — never rendering of the value itself.     | full (`3f254420`)                                                                                    | `classifyValue`; `inferColumnTypes` (95% most-specific-first)     |
| DSM5 | The library surface is `@safe pure nothrow @nogc`: borrowed input spans, `SmallBuffer`-arena storage of plain-data offsets (no `string` fields), `Expected` errors, and chunk-bounded entry points (`DSN5`) that read no clock and touch no I/O — the `sparkles:diff`/`sparkles:fuzzy` doctrine. Benchmarked from the first commit.                                                                 | partial (`3f254420`) — attributes/borrowing/`Expected`/bench ship; chunked entry points await `DSN5` | `libs/dsv` package contract; `bench.d`                            |
| DSM6 | **Projection compute** lives in the library: stable multi-key sort over typed comparators (`DSS`), typed constraint evaluation (`DSF2`), and the composed projection (a row-index permutation + column visibility/order) as a pure function of (model, spec) — deterministic, independent of chunking and enumeration order.                                                                        | not started                                                                                          | `sparkles.dsv.project`                                            |

## The grid view (`DSG`)

`DSG1`/`DSG3`/`DSG6` are phase-1 (they render through the existing md table
path); `DSG2`, `DSG4`, and `DSG5` need capabilities that path does not have
(pinned bands, per-column caps + document-scale horizontal scroll, a row
gutter) and are **post-CHK** — designed here, built against the unified table
after the checkpoint.

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                       | Status      | Traces to                                  |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ------------------------------------------ |
| DSG1 | The grid must render as the [`MDP10`](./gui.md) box-drawn table: rounded outer corners, `│` separators, bold header + heavy `┝━┿━┥` rule, light inner row rules by default, one padding cell per separator — the same widget vocabulary, so GUI/TUI/HTML parity is by construction ([`MDP-T2`](./tui.md) native glyphs in cells).                                                                                                 | not started | `viewDsv` over the shared table components |
| DSG2 | The **header row and the column-rule must stay pinned** while the document scrolls vertically (GUI/TUI: a non-scrolling band above the viewport; HTML: `position: sticky`), and the row-number gutter stays pinned horizontally — the [`COD6`](./gui.md) pinned-gutter idiom at document scale.                                                                                                                                   | not started | the dock pane's pinned header band         |
| DSG3 | Per-column alignment from type: numeric and date columns right-aligned, booleans centered, strings left — plus `missing` cells dimmed and `ragged` overflow tinted; the slots come from the theme like every widget ([`THM`](../ui/theme.md)).                                                                                                                                                                                    | not started | `viewDsv` alignment from `ColumnType`      |
| DSG4 | A grid wider than the pane must scroll **horizontally** behind the frame with the border scrollbar (the [`COD6`](./gui.md) bottom-border bar, `ScrollView` machine, wheel-sideways/Shift+wheel), the row-number gutter pinned; per-column width is capped (provisional: 64 cells) with overlong cell text ellipsized — the full value remains reachable by copy and (deferred) the cell peek `DSZ3`.                              | not started | `ScrollView`; `resolveTracks` width caps   |
| DSG5 | The **row-number gutter** numbers data records 1-based in **source order** (the header row unnumbered), and keeps showing _source_ record numbers under any projection — a sorted/filtered view reveals provenance instead of renumbering (the VisiData reading). Gutter content is excluded from selection ([`SEL2`](./gui.md)).                                                                                                 | not started | gutter runs without `srcStart`             |
| DSG6 | **Sink parity**: non-interactive ANSI emits the whole grid once (the pager case — projection controls do not apply, [`ANS3`](./feature-requirements.md) shape) with cells wrapped by the existing table wrap when the terminal is narrower than the grid; HTML emits a semantic `<table>` (`<thead>`/`<th scope>`/`<td>`) with theme CSS and sticky header — static, so browser-side sort/filter is out of scope for the v1 emit. | not started | the ANSI/HTML sink arms                    |

## Browser state (`DSB`)

The interactive tier is one **projection** value — sort keys + filter + column
visibility/order — owned by a presentation-free state machine, applied by
`DSM6`, painted by `DSG`.

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                         | Status      | Traces to                            |
| ---- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ------------------------------------ |
| DSB1 | The projection must be a single regular value (`ProjectionSpec`): ordered sort keys with per-key direction, the filter AST, and the column order/visibility list. Every mutation route — header click, keymap, filter bar, header menu, columns palette — edits this one value; the machine is presentation-free and unit-tested (the [`TBL5`](./gui.md) doctrine). | not started | `dsv_browser.d` (pure machine)       |
| DSB2 | **Pristine is a state**: a one-key reset returns to source order, no filter, all columns, and the chrome must make non-pristine visually unmissable (`DSK5`) — because copy semantics differ there (`DSC4`/`DSC5`).                                                                                                                                                 | not started | `ProjectionSpec.pristine`; reset key |
| DSB3 | **Column hide/reorder** must be reachable from the keymap and from a **columns palette** — a picker-style list of columns with visibility toggles and move-up/down ([`DEF23`](./feature-requirements.md) look, [`TRV`](./tree-view.md) list machinery); pointer drag-reorder of header cells is deferred (`DSZ4`).                                                  | not started | columns palette; `keymap.d` bindings |
| DSB4 | Projection changes on large documents run as **background jobs** (`DSN5`) with progress in the status chrome and cancellation on any newer projection edit; the visible grid stays interactive on the previous projection until the new one lands (no half-applied views).                                                                                          | not started | the event-horizon job runner         |
| DSB5 | All browser keys route through hue's **one binding table** ([`KEY`](./lantern.md)) so lantern lists them and [`CFG6`](./config.md) can rebind them.                                                                                                                                                                                                                 | not started | `keymap.d`                           |

## Sorting (`DSS`)

| ID   | Requirement                                                                                                                                                                                                                                                                                                                         | Status      | Traces to                                |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ---------------------------------------- |
| DSS1 | **Multi-key sort with explicit UI**: header click (or the sort key on the focused column) cycles the column asc → desc → removed as the **primary** key, demoting existing keys; Shift+click (and a keymap chord) **appends** the column as the next key instead. The header cell shows each key's rank and direction (`1▲`, `2▼`). | not started | `ProjectionSpec.sortKeys`; header chrome |
| DSS2 | Comparison is **typed** per `DSM4`: numeric/date/bool keys compare by value, strings by Unicode-aware folded comparison; cells that fail the column's type (and `missing` cells) group **after** all typed values, comparing as strings among themselves — so a dirty column still sorts usefully.                                  | not started | `sparkles.dsv.project` comparators       |
| DSS3 | The sort must be **stable** with the source record index as the final tiebreak — a total, deterministic order (the `sparkles:fuzzy` invariant-6 doctrine), independent of chunking and identical across sinks and platforms.                                                                                                        | not started | stable merge in `project`                |

## Filtering (`DSF`)

Two surfaces, one truth: header menus **compile into the same query AST** the
filter bar edits, so the bar always displays the whole active filter.

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                                         | Status      | Traces to                              |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | -------------------------------------- |
| DSF1 | The **filter bar** follows the picker's query doctrine ([`PKQ`](./picker.md); the `sparkles:fuzzy` SPEC's lexing — whitespace tokens, quoting, `\`-escapes, `!` negation): a query splits into **column constraints** plus a **fuzzy remainder**, parsing borrows the input and allocates nothing.                                                                                                                                                  | not started | filter-bar parser over the fuzzy lexer |
| DSF2 | Column constraints are `name:value` forms with typed operators: `name:text` (case-folded contains), `name:=text` (exact), `name:>n` `name:>=n` `name:<n` `name:<=n` (typed numeric/date comparison), `name:` (empty cell), each negatable (`!region:EU`). `name` resolves case-insensitively against headers (quoted when it contains spaces); `#3:` addresses a column by 1-based index. Constraints AND; evaluation is `sparkles:dsv`'s (`DSM6`). | not started | `sparkles.dsv.project` constraint eval |
| DSF3 | The **fuzzy remainder** must match rows by cell through `sparkles:fuzzy` (`generalLanguage` profile; a row admits when any visible cell admits the part), with matched positions highlighted in the grid ([`PKQ6`](./picker.md) analog). The host ANDs constraint results with remainder admission — neither engine depends on the other.                                                                                                           | not started | `sparkles:fuzzy` `match`/`positions`   |
| DSF4 | **Header menus** offer the per-column quick filters — contains / equals / range / empty — as a popup on the header cell ([`popup`](../ui/popup.md) machinery); applying one splices the corresponding constraint into the AST (visible in the bar, removable from either surface). Value-set enumeration (a distinct-values checklist) is deferred (`DSZ5`).                                                                                        | not started | header popup → AST splice              |
| DSF5 | Filtering must report: matched/total row counts in the status chrome, live-updating as background evaluation progresses (`DSB4`); an **invalid query** keeps the previous projection and surfaces the parse error inline in the bar — it never blanks the grid.                                                                                                                                                                                     | not started | status segments; bar error state       |

## Selection & copy (`DSC`)

The grid **is** the [`TBL`](./gui.md) regime; these rows bind the DSV deltas.
`DSC1` is phase-1 by construction (inherited through the existing table path);
`DSC2`–`DSC5` are **post-CHK** — the serializer and crossing seams are exactly
what the table unification may reshape.

| ID   | Requirement                                                                                                                                                                                                                                                                                                                                                                                                                       | Status      | Traces to                                                      |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | -------------------------------------------------------------- |
| DSC1 | Smart drag, sub-cell/rect/row/column selection, Shift/Alt snapping, the whole-table copy button, and the TUI's OSC 52 route apply unchanged ([`TBL1`–`TBL6`](./gui.md), [`TSL`](./tui.md)); the serializers stay presentation-free and testable ([`TBL5`](./gui.md)).                                                                                                                                                             | not started | `table_select.d` reuse                                         |
| DSC2 | `--table-copy` grows a **`source`** mode: the selection re-emitted in the **document's own dialect** — the resolved delimiter/quote, minimal RFC 4180 quoting (quote only cells containing delimiter/quote/newline), records joined by the document's dominant terminator. `source` is the **default for DSV documents** (`tsv` stays the default for markdown tables); runtime-toggleable with the [`SEL7`](./gui.md) indicator. | not started | `TableCopyFormat.source`; [`CLI11`](./feature-requirements.md) |
| DSC3 | A text-regime drag that **crosses** the grid maps char-precise to **raw source bytes** via the identity channel (`DSM2`) — the [`TBL4`](./gui.md) crossing rule with quoted cells resolving to their raw spans.                                                                                                                                                                                                                   | not started | `cellSrc` from `DsvCell.rawSpan`                               |
| DSC4 | **Whole-document reproduction** ([`SEL8`](./gui.md)): in the **pristine** projection, selecting the whole document reproduces the input file byte-for-byte — BOM, quoting, mixed terminators, ragged rows and all.                                                                                                                                                                                                                | not started | contiguous raw-span discipline                                 |
| DSC5 | Under a **non-pristine** projection, copying is **WYSIWYG over the projection**: grid-regime copies serialize the visible rows/columns in view order (all formats); `DSC4`'s byte-reproduction guarantee is explicitly scoped to pristine, and the chrome's projection indicator (`DSB2`) is what tells the user which contract is live.                                                                                          | not started | serializers over the projection permutation                    |

## Scale (`DSN`)

The normative target is **~100 MB / 1M rows** interactive — a data browser
that dies at 1 MB isn't one. Correctness ships first; the machinery is staged
post-CHK (provisional D5). `DSN1` alone is phase-1: it is a property of the
D0 model, not of the renderer.

| ID   | Requirement                                                                                                                                                                                                                                                                                                                   | Status            | Traces to                                       |
| ---- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------- | ----------------------------------------------- |
| DSN1 | The model must hold **offsets, not copies**: the source stays one borrowed buffer; the record index and cell spans are arena-stored integers, so resident overhead is proportional to record count, not content size.                                                                                                         | full (`3f254420`) | `DsvDoc` span arenas over the borrowed `source` |
| DSN2 | The **record index** (quote-aware record boundaries — the one inherently sequential pass) must build lazily/in the background; the sample-parsed head renders immediately and the scrollbar range grows as indexing progresses (the status chrome shows progress).                                                            | not started       | background index job; `DSB4` runner             |
| DSN3 | Column widths, dialect, types, and the header heuristic come from the bounded **sample** (`DSD` preamble) — never a whole-file scan; widths are stable thereafter (no reflow as later rows appear).                                                                                                                           | not started       | `sniff`/width measurement over sample           |
| DSN4 | Rendering must be **viewport-culled** ([`RND1`](./gui.md)): only visible rows are decoded and laid out per frame; scroll cost must not grow with row count.                                                                                                                                                                   | not started       | `viewDsv` windowed materialization              |
| DSN5 | Sort/filter/index execution must be **chunk-bounded pure calls** (the `sparkles:fuzzy` `searchChunk` shape): the library exposes resumable cursors, hue schedules chunks on the [`event-horizon`](../event-horizon/SPEC.md) pool with cancellation between chunks; results are deterministic regardless of chunking (`DSS3`). | not started       | `sparkles.dsv.project` cursors; `DSB4`          |
| DSN6 | Provisional budgets, to be calibrated with benchmarks: first grid paint of a 100 MB file ≤ 300 ms (sample-parsed head); full index of 1M rows in the background ≤ 2 s; sort of 1M indexed rows ≤ 1 s; filter keystroke-to-first-results ≤ 100 ms. A `libs/dsv/bench/` harness pins them.                                      | not started       | `libs/dsv/bench/`                               |

## Deferred (`DSZ`)

| ID   | Requirement                                                                                                                                                                                                                                   | Status      | Traces to                          |
| ---- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- | ---------------------------------- |
| DSZ1 | **DSV diff** — `hue diff a.csv b.csv` as a **cell-level** diff (daff-style): row alignment via `sparkles:diff`, changed cells tinted in the grid through the preview-diff decoration channel ([`MDP21`](./gui.md), [`DVN6`](./diff-view.md)). | not started | `sparkles:diff` + grid decorations |
| DSZ2 | **Rainbow raw view** — per-column color in `--raw` (Rainbow CSV): either a bundled tree-sitter CSV grammar or a `sparkles:dsv`-driven highlight-event stream into the existing ANSI/HTML renderers.                                           | not started | `DSK4`; highlight-event synthesis  |
| DSZ3 | **Cell peek** — a popup showing a truncated cell's full value ([`popup`](../ui/popup.md)), with copy.                                                                                                                                         | not started | `DSG4` ellipsis sites              |
| DSZ4 | **Pointer drag-reorder** of header cells (the keymap/palette route `DSB3` ships first).                                                                                                                                                       | not started | header drag machine                |
| DSZ5 | **Distinct-values menu** — a header-menu checklist of a column's value set with counts (needs a full-column scan; rides the `DSN5` job runner).                                                                                               | not started | `DSF4`                             |
| DSZ6 | **Frozen data columns** — pinning the first N data columns against horizontal scroll (the gutter idiom generalized).                                                                                                                          | not started | `DSG4`                             |
| DSZ7 | **Number/date display formatting** (thousands separators, locale decimal comma detection for semicolon dialects) — display-only, never mutating copy fidelity.                                                                                | not started | `DSM4` inference notes             |

## Milestones

**Phase 1** runs in parallel with the table-rendering unification (separate
worktree) and must not conflict with it: D0 is pure library work, and D1
consumes the existing md table rendering path as-is.

| Milestone              | Delivers                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                              | Gate                                                                                                                                       |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------ |
| **D0** ✅ (`3f254420`) | Basic `sparkles:dsv` — dialect seed + sniff (`DSD1`–`DSD4`, `DSD6`), RFC parser + identity channel (`DSM1`–`DSM3`), typed columns (`DSM4`), offsets-not-copies storage (`DSN1`). No hue or `sparkles:ui` code touched.                                                                                                                                                                                                                                                                                                | unit-tested pure lib; adversarial fixtures (quotes-in-quotes, ragged, CRLF/BOM, huge cells); bench baseline                                |
| **D1**                 | Basic hue preview — the content kind (`DSK1`–`DSK4`, `DSK5`'s dialect readout) rendered in all four sinks **through the existing md table rendering path**: `DsvDoc` adapted onto the same table model `viewMarkdown`'s table case consumes (`DSG1`/`DSG3`/`DSG6`), inheriting that path's current limits — no pinned header, no width caps / document h-scroll, no row gutter (`DSG2`/`DSG4`/`DSG5` wait for CHK). The `TBL` selection/copy regime is inherited by construction (`DSC1`, tsv/markdown formats only). | golden frames GUI/TUI/ANSI/HTML; `DSD5` stdin/txt sniff; **zero edits under `sparkles.ui.components.table`** (the parallel-work invariant) |

**CHK — re-orientation checkpoint.** Not a feature milestone. Entered when
**both** (a) D0 + D1 have shipped and (b) the table-rendering unification has
merged. At CHK: rebase this branch onto the unified pipeline, port the D1
adapter to it, then **audit and rewrite the plan below** — for each `DSG`/`DSC`
row, record whether the unified table satisfies it, changes its shape, or
obsoletes it, and re-sequence D2+ accordingly. The milestone rows above are
normative; everything below is a **pre-CHK sketch** kept so the target is
visible, and is expected to be redone at CHK.

| Milestone (provisional, re-planned at CHK) | Sketch                                                                                                                       |
| ------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------- |
| **D2**                                     | The full grid on the unified table: pinned header (`DSG2`), width caps + document h-scroll (`DSG4`), the row gutter (`DSG5`) |
| **D3**                                     | DSV copy deltas (`DSC2`–`DSC5`): the `source` format, char-precise crossing, pristine reproduction                           |
| **D4**                                     | The browser (`DSB`/`DSS`/`DSF`): projection machine, multi-key sort, filter bar + header menus, columns palette              |
| **D5**                                     | Scale (`DSN2`–`DSN6`): background index, chunked jobs, the 100 MB / 1M-row budgets pinned by `libs/dsv/bench/`               |

## Cross-references (threading status)

**Threaded with this spec**: [feature-requirements.md](./feature-requirements.md)
`CLI26` (the `--dsv` family), `MOD10` (DSV as a content kind), `DEF28` (the
roadmap row), and `CLI11`'s planned-`source` note; [index.md](./index.md)'s
Documentation-map row, ID-scheme mnemonics, and mode-map note; the
[gui.md](./gui.md) `TBL` preamble pointer.

**Threaded with D0** (`3f254420`): the `AGENTS.md` `sparkles:dsv` sub-package
row; the module-coverage table below.

**Landing with later code, not before**:

- The `apps/hue` module-coverage rows here and in
  [feature-requirements.md](./feature-requirements.md) — no hue DSV files
  exist yet (D1).
- [gui.md](./gui.md) `TBL2`/`TBL6` and [tui.md](./tui.md) `TSL5`: the copy
  format set gains `source` when `DSC2` ships (post-CHK).
- [tui.md](./tui.md): a `DSV-T` parity area (by construction via `TSF3`, like
  `MDP-T`/`DIF-T`) once rows exist to bind.

## Module coverage (`sparkles:dsv`)

| Source                                | Key symbols                                                                                          | Requirements                          |
| ------------------------------------- | ---------------------------------------------------------------------------------------------------- | ------------------------------------- |
| `libs/dsv/src/sparkles/dsv/model.d`   | `Span`, `Dialect`, `DsvCell`/`DsvRecord`/`DsvDoc`, `decodeCell`, `classifyValue`, `inferColumnTypes` | `DSM2`–`DSM4`, `DSN1`                 |
| `libs/dsv/src/sparkles/dsv/parse.d`   | `parseDsv` (tolerant RFC 4180, BOM/terminators, modal/ragged accounting)                             | `DSM1`, `DSM3`, `DSD6`                |
| `libs/dsv/src/sparkles/dsv/dialect.d` | `seedForExtension`, `sniff`, `detectHeader`, `SniffResult.looksDsv`                                  | `DSD1`–`DSD3`, `DSD5`                 |
| `libs/dsv/src/sparkles/dsv/bench.d`   | parse (1k/10k rows) + sniff `--bench` baselines                                                      | `DSM5` (the benchmarked-from-D0 half) |
| `libs/dsv/dub.sdl`                    | `library`/`unittest` configurations (base-only dependency)                                           | `DSM5`                                |

→ [Feature requirements](./feature-requirements.md) · [GUI](./gui.md) ·
[TUI](./tui.md) · [Picker](./picker.md) · [Overview](./index.md)
