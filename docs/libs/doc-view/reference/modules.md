# Module reference

Every module is `sparkles.doc_view.<name>`. The first group moved from hue
unchanged in behaviour ([`UIA14`](../../../specs/hue/ui-architecture.md)); the
second is what embedding needed.

## The document pipeline (from hue)

| Module                                                              | What it holds                                                                                                                                    |
| ------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `document`                                                          | `Document`, `ContentKind`, `DocumentPipeline` — read → detect → highlight → parse, with the `fetchUrl`, `readFile` and include hooks a host sets |
| `viewer_model`                                                      | `ViewerModel`: the widget tree, its frames and display list, the identity rows, folds, search and match rects, scroll and the `NAV5` anchor      |
| `preview_model`                                                     | `PreviewModel` and `buildPreviewModel`: the markdown structure and every fence resolved once                                                     |
| `ansi_model`                                                        | the neutral styled-line types an ` ```ansi ` fence decodes to                                                                                    |
| `ansi_decode`                                                       | `decodeAnsi`, an off-screen libghostty-vt terminal; compiled where the consumer links `sparkles:ghostty`                                         |
| `dsv_view`                                                          | the DSV adapter onto the markdown table view, its model, window and copy contract                                                                |
| `table_select`                                                      | 2-D table selection and its serialisation                                                                                                        |
| `diff_session`                                                      | the changed-file session, and `selectionPatch`                                                                                                   |
| `diff_view`                                                         | the diff document view (unified and split)                                                                                                       |
| `diff_structural`, `diff_token_view`, `diff_commutative`, `md_diff` | grammar-aware diff emphasis, commutative containers, the rendered-markdown diff                                                                  |
| `coverage_discovery`, `coverage_rebase`                             | finding a coverage artifact and re-anchoring it onto the current file                                                                            |
| `document_session`                                                  | `DocumentSession`, the interface a host's per-document session (hue's format preview) attaches through                                           |

### V8 coverage snapshots

`DocumentPipeline.attachCoverage` projects a multi-script V8 artifact to the
document's path (or its title for an embedded source) before resolving sources.
Only the selected script is mapped, against the immutable UTF-8 `Document.source`
snapshot already loaded; attachment does not reread the source file from disk
or use this snapshot for unrelated scripts. Native UTF-16 producer boundaries
become exact original UTF-8 inline spans and source line numbers. An unavailable
unrelated script does not prevent the selected document's overlay.

Invalid selected-script offsets, including surrogate interiors and offsets past
the snapshot, warn and leave an undecorated document, rather than silently
clamping or skipping ranges. See the coverage library's
[snapshot and selection contract](../../code-instrumentation/reference/api.md#v8-source-snapshots-and-script-selection).

## Embedding

| Module     | What it holds                                                                                                 |
| ---------- | ------------------------------------------------------------------------------------------------------------- |
| `include`  | `expandIncludes`, VitePress `@include` resolution, confined and total (`VIW5`, `VIW7`)                        |
| `kind`     | `ViewKind`, `viewKindOf`: what the viewer can show of a file, decided before opening it (terminal `TDV1`)     |
| `view_ops` | `emitVisibleOps`, the document's paint loop shared by hue's window and the pane                               |
| `pane`     | `DocViewEnv`, `DocViewPane`, `PaneKey`, `chromeTheme`; compiled where the consumer links `sparkles:ui-raylib` |

## The pane's keys

| Keys                                                            | Action                                     |
| --------------------------------------------------------------- | ------------------------------------------ |
| `j` / `↓`, `k` / `↑`                                            | one row                                    |
| `Space` / `PgDn`, `PgUp`                                        | one page                                   |
| `Ctrl+D`, `Ctrl+U`                                              | half a page                                |
| `g g` / `Home`, `G` / `End`                                     | top, bottom                                |
| `v`                                                             | preview → highlighted → plain              |
| `l`, `c`                                                        | file line numbers, fence line numbers      |
| `/`, `n`, `N`                                                   | search, next match, previous match         |
| `z a` `z z` `z c` `z o`                                         | fold at the top row: toggle, close, open   |
| `z r`, `z m`, `z 1`–`z 9`                                       | open all, close all, fold to a level       |
| `z h` / `Shift+←`, `z l` / `Shift+→`, `Shift+Home`, `Shift+End` | sideways                                   |
| `q`, `Esc`                                                      | close the pane (`Esc` first ends a search) |
