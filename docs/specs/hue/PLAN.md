# `hue` — Delivery Status

The milestone tracker for the [hue specification](./index.md). The
specification pages state what hue must do; this page records how far each
area has been delivered, so that progress does not have to live in their prose.

Each page's own status line and requirement rows remain authoritative for its
detail. This table is the summary that the documentation map in
[index.md](./index.md) used to carry inline, as recorded there at its
2026-08-05 review. Update a row when its page's status changes.

| Area                                         | Delivery state                                                                           |
| -------------------------------------------- | ---------------------------------------------------------------------------------------- |
| [TUI requirements](./tui.md)                 | full viewer shipped (T1–T4), extending the earlier `PRV` previewer                       |
| [Android](./android.md)                      | shipped v0 (AND1–AND10)                                                                  |
| [Format preview](./format-preview.md)        | shipped v1 (FP0–FP6)                                                                     |
| [Gallery & multi-document nav](./gallery.md) | shipped (G0–G3)                                                                          |
| [Lantern](./lantern.md)                      | shipped (LT0–LT3)                                                                        |
| [Twoslash requirements](./twoslash.md)       | shipped; the page's own status line supersedes the index's earlier `planned/branch-only` |
| [Configuration](./config.md)                 | design (CFG1–CFG12)                                                                      |
| [Document chrome](./chrome.md)               | design; replaces the three private gutters hue painted before it                         |
| [Pager & streaming](./pager.md)              | design                                                                                   |
| [DSV preview](./dsv-preview.md)              | design                                                                                   |
| [Picker](./picker.md)                        | design, over the `sparkles:fuzzy` engine                                                 |
| [UI architecture](./ui-architecture.md)      | architecture                                                                             |
| [Transformer pipeline](./pipeline.md)        | architecture                                                                             |
| [Content folding](./folding.md)              | planned                                                                                  |
| [Tree / DAG view](./tree-view.md)            | planned                                                                                  |
| [Tab view](./tab-view.md)                    | planned                                                                                  |
| [Diff & PR view](./diff-view.md)             | planned                                                                                  |
| [Navigation](./navigation.md)                | planned                                                                                  |
| [Images & diagrams](./media.md)              | planned                                                                                  |
| [Overlay requirements](./overlays.md)        | planned                                                                                  |
| [Notifier requirements](./notifier.md)       | planned                                                                                  |
| [Web integration](./web-integration.md)      | planned; SSG/SSR shell-out first, a wasm client-side backend after it                    |
