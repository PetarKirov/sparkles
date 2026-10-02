# doc-view

`sparkles:doc-view` is the document viewer hue grew, as a library: load a file
as a document — source code, markdown, a DSV table, a diff, a twoslash payload
— and view it with hue's views, wrapping, folding, search and scroll
anchoring. hue mounts it as its document pane; `sparkles:terminal` opens the
files its programs ask for in it ([`UIA14`](../../specs/hue/ui-architecture.md),
[`TDV`](../../specs/terminal/viewer.md)).

It has two halves, gated on what the consumer links rather than on a
configuration of its own:

- **The model** — `DocumentPipeline` (read → detect → highlight → parse) and
  `ViewerModel` (the laid-out widget tree, its display list, folds, search,
  the scroll anchor). Raylib-free; it builds wherever hue's terminal build
  does.
- **The pane** — `DocViewPane`, the model plus keys and a GPU painter, for any
  `sparkles:ui-raylib` window. It compiles where the consumer depends on
  `sparkles:ui-raylib`; the off-screen-VT decoder for ` ```ansi ` fences where
  it depends on `sparkles:ghostty`.

The library makes no network requests and runs nothing a document names: a
URL is fetched only through a host's `DocumentPipeline.fetchUrl`, and markdown
includes stay inside the document's tree ([`VIW7`](../../specs/hue/viewer.md)).

## Documentation

- [Embed a viewer pane](how-to/embed-a-viewer-pane.md)
- [Module reference](reference/modules.md)
