# Markdown Implementation Status

The markdown spec defines the intended end state of the package. The code in `libs/markdown/src/sparkles/markdown/package.d` currently implements a narrower but already usable subset.

## Implemented Today

### Input And Lifetime Handling

- `char` and `ubyte` input ranges
- UTF-8 validation and replacement-mode decoding for byte input
- newline normalization
- explicit borrowed vs owned result storage
- `parse`, `parseBorrowed`, and `parseOwned`
- `SourceMap` line/column lookup

### Block Parsing

- ATX headings
- thematic breaks
- fenced code blocks
- paragraphs

### Inline Parsing

- text
- soft and hard line breaks
- inline code
- emphasis
- strong emphasis
- links
- images
- autolinks
- inline HTML
- strikethrough when enabled by profile or feature flags

### Rendering

- document, paragraph, heading, thematic break, fenced code, and indented code HTML
- links, images, emphasis, strong, code, strikethrough, and autolinks
- URL sanitization for `javascript:` and `vbscript:`
- safe-vs-unsafe HTML behavior for inline and block HTML

### Hooks

- preprocess hook support
- post-parse hook support
- compile-time hook capability traits

## Not Yet Implemented

The current parser surface includes many types and flags that are not yet fully exercised by parsing logic.

Notable gaps relative to the spec:

- full CommonMark compliance
- block quotes
- ordered and unordered lists
- indented code parsing
- HTML block classification
- link reference definitions
- setext headings
- tables
- task lists
- custom containers
- code groups
- TOC tokens
- math blocks and inline math
- code fence metadata parsing
- code markers
- MDX parsing
- include and code-import preprocessing
- richer extension dispatch beyond preprocess/post-parse behavior

## How To Read The API Surface

The package is intentionally shaped for the full design even where some parser branches are still stubs or placeholders.

That means:

- `AstKind` contains more variants than the current parser emits.
- `FeatureFlags` contains more switches than the current parser consumes.
- the hook traits define the intended extension seam even where the core parser still uses only part of it.

This is useful for documentation because the public direction is already visible, but consumers should treat the spec as the roadmap and `package.d` as the source of truth for current behavior.

## Recommended Usage Today

The current implementation is a good fit for:

- small Markdown-to-HTML transformations
- experimenting with profile selection and ownership contracts
- building tooling around spans, AST inspection, and event streams
- fixture-driven development of parser behavior

If you need full CommonMark compliance or VitePress/Nextra compatibility today, rely on the spec as the target rather than assuming the current parser already provides complete parity.
