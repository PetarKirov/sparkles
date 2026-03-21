# Markdown API And Types

This page documents the current public API shape exposed by `sparkles.markdown`.

## Parsing Entry Points

### `parse`

`parse` is the main entry point:

```d
auto result = parse(input, MarkdownOptions!void());
```

It accepts:

- `char` input ranges, treated as UTF-8 text
- `ubyte` input ranges, decoded according to `Utf8ErrorMode`

It returns a `ParseResult` containing:

- `events`
- `source`
- `rawBytes`
- `sourceMap`
- `diagnostics`
- `ast`
- `features`

### `parseBorrowed`

`parseBorrowed` is the hard no-copy API for slice inputs:

```d
const(char)[] doc = "# Borrowed\n";
auto result = parseBorrowed(doc);
```

Use it when you want a clear borrowed-lifetime contract.

### `parseOwned`

`parseOwned` forces the result to own its normalized source:

```d
DummyAlloc alloc;
auto result = parseOwned("# Owned\r\n", alloc);
```

This is useful when the caller does not want result lifetimes tied to the original input buffer.

## Configuration Types

### `Profile`

`Profile` selects a preset behavior surface:

- `commonmark_strict`
- `gfm`
- `vitepress_compatible`
- `nextra_compatible`
- `custom`

### `FeatureFlags`

`FeatureFlags` is the concrete feature matrix. In the current implementation, the most visible flags are:

- `strikethrough`
- `customHeadingIds`
- `headingAnchors`
- `fenceMetadata`
- `codeMarkers`
- `mdxSyntax`

Profiles are expanded by `withProfileDefaults`, then merged with any user-provided flags.

### `MarkdownOptions`

`MarkdownOptions!(Hook, Alloc)` bundles parser configuration:

- `profile`
- `features`
- `sourcePos`
- `safeMode`
- `limits`
- `utf8ErrorMode`
- `headingIdPreference`
- optional `hook`
- optional `allocator`

The `Hook` type can also contribute a compile-time `borrowPolicy`.

### `Limits`

`Limits` contains safety and resource caps:

- `maxNestingDepth`
- `maxIncludeDepth`
- `maxInputBytes`
- `maxTokenCount`

## Source And Lifetime Types

### `BorrowPolicy`

`BorrowPolicy` is the high-level input ownership contract:

- `automatic`
- `requireBorrow`
- `requireCopy`

### `SourceOwnership`

`SourceOwnership` describes what actually happened in the returned result:

- `borrowed`
- `owned`

### `SourceStorage` And `RawByteStorage`

`ParseResult.source` stores normalized text, while `ParseResult.rawBytes` stores the preserved original bytes.

### `SourceSpan`, `SourceLocation`, And `SourceMap`

The parser uses spans instead of attaching many copied strings to nodes.

- `SourceSpan` is `(offset, length)`
- `SourceMap.locationAt(offset)` converts byte offsets to `(line, column)`
- `sourceSlice(result, span)` and `rawSlice(result, span)` resolve spans back into text or raw bytes

## Structural Representations

### `AstKind` And `AstNode`

`AstNode` is the unified tree node used by the current implementation. It includes:

- structural fields such as `kind`, `span`, and `children`
- heading/list metadata such as `level`, `ordered`, `start`, and `tight`
- textual payload such as `literal`, `destination`, `title`, `alt`, and `name`
- extension-oriented fields such as `customId`, `infoString`, and `metadata`

Not every field is meaningful for every `AstKind`; the node acts as a compact tagged representation rather than many separate struct types.

### `EventKind` And `Event`

The event stream is derived from the AST and is intended for lightweight consumers.

Important event kinds:

- `enter`
- `exit`
- `text`
- `code`
- `softBreak`
- `hardBreak`
- `thematicBreak`

### `ParseResult`

`ParseResult` is the central return type. It keeps both the tree and stream representations so callers do not need to choose up front.

## Rendering API

### `renderHtml`

`renderHtml` writes HTML to any `char` output range:

```d
auto writer = appender!string();
result.renderHtml(writer);
```

Use it when you want control over allocation.

### `toHtml`

`toHtml` is the convenience wrapper that returns a `string`.

### `RenderOptions`

`RenderOptions` currently exposes:

- `unsafeHtml`
- `sourcePos`
- `softBreakAs`

## Hook Surface

The parser uses capability traits instead of a required interface. The public hook-related types are:

- `ParseContext`
- `LineScanner`
- `BlockStack`
- `DelimiterStack`
- `ParseError`
- `ErrorAction`
- `BlockStart`

The current public traits are:

- `hasPreprocessDocument`
- `hasTryStartBlock`
- `hasTryParseInline`
- `hasOnPostParse`
- `hasOnRenderNode`
- `hasOnError`

This keeps the extension model opt-in and zero-cost when the hook type is `void`.
