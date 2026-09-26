# markdown

`sparkles:markdown` is the repository's Markdown parser and renderer subpackage.

The long-term target is described in [the Markdown parser spec](../../specs/markdown/SPEC.md). The current implementation already exposes the intended public API shape: profile-aware parsing, explicit ownership contracts, a flat event stream plus AST, HTML rendering helpers, and testing utilities for fixture-driven validation.

## Runnable Examples

### Parse Markdown to HTML

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "markdown_doc_parse_html"
    dependency "sparkles:markdown" version="*"
+/

import std.stdio : writeln;

import sparkles.markdown : parse, toHtml;

void main()
{
    auto result = parse("# Hello\n\nWelcome to *Sparkles*.");
    writeln(toHtml(result));
}
```

<!-- md-example-expected
<h1>Hello</h1>
<p>Welcome to <em>Sparkles</em>.</p>
-->

```
<h1>Hello</h1>
<p>Welcome to <em>Sparkles</em>.</p>

```

### Use a Compatibility Profile

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "markdown_doc_profile"
    dependency "sparkles:markdown" version="*"
+/

import std.stdio : writeln;

import sparkles.markdown : MarkdownOptions, Profile, parse, toHtml;

void main()
{
    auto opts = MarkdownOptions!void(profile: Profile.vitepress_compatible);
    auto result = parse("## Intro {#intro}\n\n~~done~~", opts);
    writeln(toHtml(result));
}
```

<!-- md-example-expected
<h2 id="intro">Intro</h2>
<p><del>done</del></p>
-->

```
<h2 id="intro">Intro</h2>
<p><del>done</del></p>

```

### Borrowed vs Owned Source

```d
#!/usr/bin/env dub
/+ dub.sdl:
    name "markdown_doc_ownership"
    dependency "sparkles:markdown" version="*"
+/

import std.conv : to;
import std.stdio : writeln;

import sparkles.markdown :
    SourceSpan,
    parseBorrowed,
    parseOwned,
    sourceSlice;

struct DummyAlloc
{
}

void main()
{
    const(char)[] borrowedDoc = "# Borrowed\n";
    auto borrowed = parseBorrowed(borrowedDoc);

    DummyAlloc alloc;
    auto owned = parseOwned("# Owned\r\n", alloc);

    writeln(borrowed.source.ownership.to!string);
    writeln(owned.source.ownership.to!string);
    writeln(sourceSlice(owned, SourceSpan(2, 5)));
}
```

<!-- md-example-expected
borrowed
owned
Owned
-->

```
borrowed
owned
Owned
```

## Architecture Overview

The current parser follows the same broad shape as the spec:

1. Input is normalized by `normalizeInput`, which handles UTF-8 decoding, newline normalization, and borrow-vs-copy decisions.
2. `withProfileDefaults` expands the selected `Profile` into concrete `FeatureFlags`.
3. Optional preprocess hooks can rewrite the normalized input before parsing.
4. `parseDocument` builds a tree of `AstNode` values from block parsing plus inline parsing.
5. `astToEvents` derives the flat `EventStream` used for streaming-style consumers.
6. `renderHtml` and `toHtml` render the AST to HTML.
7. Optional post-parse hooks can observe or rewrite the event stream.

In the current implementation, `parseDocument` handles:

- ATX headings
- Thematic breaks
- Fenced code blocks
- Paragraphs
- Inline code
- Emphasis and strong emphasis
- Links and images
- Autolinks and inline HTML
- Strikethrough when enabled by profile or explicit feature flags
- VitePress/Nextra-style custom heading IDs when `customHeadingIds` is enabled

The spec goes further than the current parser. Features such as full CommonMark compliance, block quotes, lists, tables, MDX, include processing, and richer extension behavior are design targets rather than fully implemented behavior today.

## Common Types

The most important public types in `sparkles.markdown` are:

- `Profile`: named presets such as `commonmark_strict`, `gfm`, `vitepress_compatible`, and `nextra_compatible`
- `FeatureFlags`: the concrete feature switches used by `Profile.custom` or as profile defaults
- `Limits`: parser safety limits such as nesting depth, include depth, max input bytes, and token count
- `BorrowPolicy` and `SourceOwnership`: the explicit lifetime contract for normalized source text
- `SourceSpan`, `SourceLocation`, and `SourceMap`: offset-based source tracking and lazy line/column lookup
- `AstKind` and `AstNode`: the tree representation
- `EventKind` and `Event`: the flat event-stream representation
- `MarkdownOptions`: the parse configuration, including profile, feature flags, hook type, UTF-8 policy, and heading-ID preference
- `ParseResult`: the combined output containing events, AST, source storage, raw bytes, source map, diagnostics, and active features
- `RenderOptions`: HTML rendering controls such as `unsafeHtml`, `sourcePos`, and soft-break behavior

The companion module `sparkles.markdown.testing` adds fixture-oriented types such as `FixtureCase`, `FixtureRunOptions`, `SuiteSummary`, and helpers for JSONL fixture corpora.

## General Design Patterns

The markdown package follows the same design patterns used elsewhere in Sparkles:

- Span-first data model: `SourceSpan` is authoritative, while string slices are convenience views.
- Borrow-first parsing: slice inputs stay borrowed unless normalization or policy requires ownership.
- Tree plus stream: the parser keeps both `AstNode` and `EventStream` so consumers can choose the cheaper or more convenient form.
- Shell with hooks: preprocess, post-parse, render, and error hooks are all discovered by capability traits.
- Profile-driven behavior: preset profiles are converted into feature flags rather than hard-coding behavior in many places.
- Output-range rendering: `renderHtml` writes to any `char` output range, while `toHtml` is the allocating convenience wrapper.

## Source Layout

- `libs/markdown/src/sparkles/markdown/package.d`: parser API, input normalization, AST/event generation, and HTML rendering
- `libs/markdown/src/sparkles/markdown/testing.d`: fixture loading, canonicalization, suite execution, and summary helpers
- `libs/markdown/examples/inspect_tree.d`: CLI utility for visualizing the AST as a tree
- `libs/markdown/tests/`: corpus, adapters, runners, and canonicalization helpers

## Detailed Docs

- [API and Types](./api-and-types.md)
- [Implementation Status](./implementation-status.md)
- [Testing Helpers](./testing.md)
- [Markdown specs](../../specs/markdown/)
