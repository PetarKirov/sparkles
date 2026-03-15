# Sparkles Markdown Parser Specification

## Status

Draft v0.1

## Goal

Design a **best-in-class**, **spec-compliant**, **high-performance** Markdown engine for Sparkles, implemented in D, with:

1. Full CommonMark compatibility.
2. Opt-in support for all VitePress and Nextra markdown/MDX extensions and behaviors.
3. A rigorous, multi-ecosystem conformance suite.
4. Reproducible, cross-language benchmarks.

## Design Principles

This design follows Sparkles engineering guidance from [Code Style][code-style-guide], [Functional & Declarative Programming][functional-guidelines], [Design by Introspection][dbi-intro], and the [Sean Parent research index][sean-parent-index], and explicitly applies:

1. [Local reasoning][sean-local-reasoning] and explicit [contracts][sean-contracts].
2. [Functional, pipeline-oriented processing][functional-guidelines] where possible.
3. [Design-by-introspection][dbi-guidelines] (DbI): shell + optional hooks.
4. Clear separation between parsing semantics and rendering/presentation semantics.

## Non-Goals

1. Full VitePress site-generation behavior (routing, Vite asset graph, Vue compilation) inside the parser.
2. A browser runtime.
3. Non-markdown authoring UI/editor concerns.

## Deliverables

1. `libs/markdown` parser package.
2. `libs/markdown/SPEC.md` (this document).
3. [`libs/markdown/TESTING.md`][markdown-testing-spec] (detailed conformance, compatibility, adversarial, and benchmark strategy).
4. Conformance and compatibility corpus with provenance metadata.
5. Benchmark harness with adapters for major parsers.

## Compliance Targets

## CommonMark

1. Target spec: **CommonMark 0.31.2**.
2. Requirement: 100% pass on official CommonMark examples.
3. Requirement: linear-time behavior on known pathological families.

## GFM and Adjacent Extensions

1. VitePress-compatible surface should be available behind options.
2. Default mode remains strict CommonMark (+ minimal safety defaults).

## Nextra / MDX Compatibility

1. Provide a `nextra_compatible` profile that supports Nextra markdown + MDX authoring expectations.
2. Treat JSX/ESM in `.mdx` as first-class syntax in Nextra profile.
3. Keep Markdown-only profile independent from MDX-specific semantics.

## VitePress and Nextra Extension Matrix

The parser must support syntax and metadata needed by VitePress and Nextra features. Some are parse-time; others are transform/render-time.

### VitePress

| Feature                  | Syntax/Behavior                           | Phase                            | Default                 |
| ------------------------ | ----------------------------------------- | -------------------------------- | ----------------------- |
| Header anchors           | auto IDs for headings                     | post-parse transform             | on                      |
| Custom anchors           | `# Title {#id}`                           | block parse + post-parse         | on                      |
| Internal links           | `.md`/`.html`/extensionless normalization | render transform                 | on                      |
| External links attrs     | `target="_blank" rel="noreferrer"`        | render transform                 | on                      |
| YAML frontmatter         | leading `---` block                       | pre-parse split                  | on                      |
| GFM tables               | pipe table syntax                         | block extension                  | on in vitepress profile |
| Emoji shortcodes         | `:tada:`                                  | inline extension                 | on in vitepress profile |
| TOC token                | `[[toc]]`                                 | block extension + post transform | on in vitepress profile |
| Custom containers        | `::: info`, `::: tip`, etc                | block extension                  | on in vitepress profile |
| Container attrs          | e.g. `{open}`                             | attribute parser extension       | on in vitepress profile |
| `raw` container          | `::: raw`                                 | block extension + render hint    | on in vitepress profile |
| GFM alerts               | `> [!NOTE]` etc                           | block extension                  | on in vitepress profile |
| Fence language/meta      | ` ```ts {1} :line-numbers `               | fence info/meta parser           | on                      |
| Line highlight           | `{1,3-5}` and marker comments             | code metadata transform          | on in vitepress profile |
| Focus/diff/error markers | `[!code focus]`, `[!code --]`, etc        | code metadata transform          | on in vitepress profile |
| Line numbers             | global + per-block override               | render transform                 | on in vitepress profile |
| Line numbers start       | `:line-numbers=2` custom start number     | code metadata transform          | on in vitepress profile |
| Code import              | `<<< @/file{...}`                         | preprocessor                     | on in vitepress profile |
| Code snippet regions     | `#region`/`#endregion` markers in source  | preprocessor                     | on in vitepress profile |
| Code group snippet title | inferred from imported file path          | code metadata transform          | on in vitepress profile |
| Code groups              | `::: code-group`                          | block extension                  | on in vitepress profile |
| Markdown include         | `<!--@include: ...-->`                    | preprocessor                     | on in vitepress profile |
| Include heading anchor   | `<!--@include: ./file.md{#heading}-->`    | preprocessor                     | on in vitepress profile |
| Math equations           | `$...$`, `$$...$$`                        | inline/block extension           | off (opt-in)            |
| Image lazy loading       | `loading="lazy"` behavior                 | render transform                 | off                     |

### Nextra

| Feature                        | Syntax/Behavior                             | Phase                         | Default              |
| ------------------------------ | ------------------------------------------- | ----------------------------- | -------------------- |
| MDX support                    | ESM imports/exports + JSX in `.mdx`         | mdx parse mode                | on in nextra profile |
| GFM core                       | strikethrough/tasklist/table/autolink       | block+inline extension        | on in nextra profile |
| Custom heading id              | `## Heading [#custom-id]`                   | heading post-process          | on in nextra profile |
| GitHub alerts                  | `> [!NOTE]` etc mapped to callout semantics | block extension + render hint | on in nextra profile |
| Code fence line highlight      | ` ```js {1,4-5} `                           | code metadata parse           | on in nextra profile |
| Code fence substring highlight | ` ```js /useState/ `                        | code metadata parse           | on in nextra profile |
| Code copy button metadata      | ` ```js copy ` / `copy=false`               | code metadata parse           | on in nextra profile |
| Code line numbers metadata     | ` ```js showLineNumbers `                   | code metadata parse           | on in nextra profile |
| Code filename/title metadata   | ` ```js filename="example.js" `             | code metadata parse           | on in nextra profile |
| Inline code language hint      | `` `let x = 1{:jsx}` ``                     | inline code extension         | on in nextra profile |
| Mermaid blocks                 | ` ```mermaid `                              | fenced block extension        | on in nextra profile |
| LaTeX inline                   | `$...$` when `latex` enabled                | inline extension              | off (opt-in)         |
| LaTeX display                  | ` ```math ` fenced blocks                   | fenced block extension        | off (opt-in)         |
| Internal links                 | markdown links transformed to app links     | render transform              | on in nextra profile |
| Static markdown image          | `![](...)` to image component semantics     | render transform              | on in nextra profile |

## Profiles

The engine exposes explicit profiles:

1. `commonmark_strict`.
2. `vitepress_compatible`.
3. `nextra_compatible`.
4. `gfm`.
5. `custom` (feature set assembled from options).

## Architecture

## High-Level Pipeline

```text
input source (slice or range of ubyte/char)
  -> UTF-8 decoding (ubyte input only) + newline normalization
  -> preprocessors (optional: include, snippet import, frontmatter split)
  -> block parser (Markdown) / MDX parser (profile-dependent)
  -> inline parser
  -> event stream
  -> AST builder (optional)
  -> post-parse transforms (anchors, toc, code metadata)
  -> renderer(s): HTML / XML / CommonMark / event sink
```

Input may be a range of `ubyte` (raw bytes requiring UTF-8 decoding) or a range of `char` (assumed valid UTF-8). Slice inputs (`const(ubyte)[]`, `const(char)[]`) are a special case of ranges and can avoid copying when ownership policy permits borrowing.

## Memory Model and Lifetime Semantics

The parser exposes two orthogonal contracts that must always be explicit:

1. **Source ownership**: whether `ParseResult` borrows caller memory or owns a parser-managed copy.
2. **Allocation strategy**: where parser state (events, AST nodes, rewrite buffers) is allocated.

### Input Abstraction Matrix

| Input Category          | Example Types                                        | `BorrowPolicy.auto` Behavior                                                | Copy Required | Lifetime Contract                                                                                  |
| ----------------------- | ---------------------------------------------------- | --------------------------------------------------------------------------- | ------------- | -------------------------------------------------------------------------------------------------- |
| GC immutable slice      | `immutable(char)[]`, `immutable(ubyte)[]`            | Borrow source by default                                                    | No            | Borrowed slices are effectively unbounded (GC-managed) for parser/result lifetime needs.           |
| Non-GC const slice      | `const(char)[]`, `const(ubyte)[]`                    | Borrow source by default                                                    | No            | Caller must keep backing memory alive for as long as any borrowed `ParseResult`/AST/event is used. |
| Forward or better range | `ForwardRange`/`RandomAccessRange` of `char`/`ubyte` | Borrow if stable contiguous view exists; otherwise materialize owned source | Sometimes     | If borrowing is not provably safe, parser materializes and marks result as owned.                  |
| Strict input-only range | `InputRange` (not forward) of `char`/`ubyte`         | Always materialize owned source                                             | Yes           | Parser buffers normalized UTF-8 using configured allocator before block parsing.                   |

### SourceSpan as Canonical Text Reference

`SourceSpan` is the canonical identity for textual payload (`byteOffset + byteLength + line/column`). This keeps core parse data memory-model-agnostic and avoids forcing borrowed slices into every node.

1. Events always carry spans.
2. AST nodes carry spans and may additionally expose convenience `const(char)[]` views.
3. Consumers that need lifetime-independent storage copy text explicitly from spans (`sourceSlice(result, span)` pattern).

### Borrowed vs Owned Result Contracts

1. **Borrowed result** (`SourceOwnership.borrowed`): no source copy; caller owns lifetime obligations.
2. **Owned result** (`SourceOwnership.owned`): parser stores normalized source in allocator-backed storage owned by the result.
3. `BorrowPolicy.auto` is borrow-first for `const(T)[]` and `immutable(T)[]`; it may downgrade to owned storage when borrowing becomes invalid.
4. `BorrowPolicy.requireBorrow` is a hard contract: if borrowing cannot be honored, parse fails with a diagnostic instead of silently copying.
5. `BorrowPolicy.requireCopy` is a hard contract: parser always decouples result lifetime from caller memory.

### Mixed-Ownership Source Rope for Rewrites

Preprocessors (especially include/snippet expansion) may produce documents that combine borrowed and owned segments. The normalized source model supports a rope-like representation where each segment carries ownership metadata.

1. Each rope segment is either borrowed (`const(char)[]` view into caller memory) or owned (allocator-backed copied text).
2. The aggregate rope lifetime must not exceed the lifetime of any borrowed segment it references.
3. Include expansion should preserve borrowing for untouched segments when valid, and allocate only rewritten/inserted segments.
4. When rope flattening is required (e.g., contiguous buffer for hot parse loops), flattening uses allocator-backed owned storage.

## CommonMark Parsing Algorithm

The parser follows the two-phase strategy described in the CommonMark spec appendix "A parsing strategy." This section summarizes the algorithm to guide implementation.

### Phase 1: Block Structure

Block structure is determined by a line-by-line scan of the input. The parser maintains a stack of open block containers.

#### Line Classification

Each input line is classified by testing (in order):

1. **Blank line** — empty or whitespace-only.
2. **Thematic break** — three or more `*`, `-`, or `_` (optionally space-separated).
3. **ATX heading** — 1–6 `#` characters followed by space or end of line.
4. **Fenced code open/close** — three or more backticks or tildes; close must match open fence character and be at least as long.
5. **HTML block start** — one of the seven HTML block start conditions (CommonMark §4.6).
6. **Block quote marker** — `>` optionally followed by a space.
7. **List item marker** — bullet (`-`, `*`, `+`) or ordered (`1.`, `1)`) followed by 1–3 spaces.
8. **Indented code** — 4+ spaces of indentation (only when not in a paragraph continuation context).
9. **Setext heading underline** — `=` or `-` characters (only when closing an open paragraph).
10. **Continuation** — anything else continues the current open block.

#### Open/Close State Machine

- New blocks are pushed onto the open block stack when their start condition matches.
- On each line, the parser walks the open block stack from root to tip, checking whether each open block accepts the line as a continuation.
- A block that does not accept continuation is **closed** (finalized and removed from the stack).
- **Lazy continuation**: paragraph lines can continue inside block quotes and list items without repeating the container markers.

#### Rule Precedence

When multiple block starts could match, the following precedence applies:

1. Block quote markers (highest).
2. List item markers.
3. Indented code blocks (only if no open paragraph).
4. Paragraph continuation (lowest — default fallback).

### Phase 2: Inline Parsing

After block structure is finalized, the contents of leaf blocks (paragraphs, headings, etc.) are parsed for inline content.

#### Delimiter Run Algorithm

Emphasis and links use the delimiter run algorithm (CommonMark §6.2):

1. Scan text left-to-right, pushing potential openers (`*`, `_`, `[`) onto a delimiter stack.
2. When a potential closer is found, search the stack for a matching opener.
3. If a match is found, emit the appropriate inline node (emphasis, strong, link) and remove delimiters between opener and closer.
4. Unmatched delimiters are emitted as literal text.

#### Bracket Matching

Links and images use a separate bracket stack:

1. `[` pushes a bracket marker.
2. `]` triggers a look-ahead for `(...)` or `[...]` link destinations.
3. On match, the bracket and its contents become a `Link` or `Image` node.
4. After a link is closed, all `[` markers inside it are deactivated (links cannot nest).

#### Inline Precedence

1. Code spans (backtick matching) — highest, contents are literal.
2. Autolinks and raw HTML — next, detected before delimiter processing.
3. Links/images — bracket matching with deactivation.
4. Emphasis/strong — delimiter run algorithm.
5. Hard/soft line breaks — lowest.

### Backtrack Avoidance and O(n) Guarantee

The parser must guarantee O(n) time complexity for all inputs. This is achieved by:

1. **Bounded delimiter stack processing**: when a closer is found, the scan for a matching opener is bounded — openers that cannot match are removed from the stack, preventing repeated scans.
2. **Single-pass block parsing**: each line is examined once; continuation checks walk only the open block stack (bounded by nesting depth limit).
3. **No regex in hot paths**: all pattern matching uses hand-written scanners with explicit state.
4. **Nesting depth limit**: a hard cap prevents stack depth from growing unboundedly.

## Core Representation

1. Event stream is the primary representation for performance and streaming-style transforms.
2. AST is optional and built from events for consumers needing tree surgery.
3. Source positions are carried in both forms.
4. In MDX-enabled profiles, AST must preserve JSX and ESM node boundaries losslessly.

## AST Node Types

The following node types define the complete AST vocabulary. Each node carries a source span (byte offset + line/column). Extension origin is encoded in the type itself — each extension contributes distinct node types.

### Block Nodes

| Node               | Key Fields                      | Notes                              |
| ------------------ | ------------------------------- | ---------------------------------- |
| `Document`         | children                        | Root node                          |
| `BlockQuote`       | children                        | `>` container                      |
| `List`             | ordered, start, tight, children | Ordered/unordered, tight/loose     |
| `ListItem`         | children, taskStatus            | Optional task checkbox             |
| `Paragraph`        | inlines                         | Leaf block                         |
| `Heading`          | level (1–6), inlines, customId  | Optional `{#id}` anchor            |
| `ThematicBreak`    | —                               | `---`, `***`, `___`                |
| `FencedCode`       | infoString, metadata, literal   | Metadata: line highlights, markers |
| `IndentedCode`     | literal                         | 4-space indented blocks            |
| `HtmlBlock`        | literal                         | Raw HTML blocks (7 types)          |
| `Table`            | alignments, children            | GFM pipe tables                    |
| `TableRow`         | isHeader, children              | Header or body row                 |
| `TableCell`        | alignment, inlines              | Individual cell                    |
| `CustomContainer`  | type, title, attrs, children    | `::: info`, `::: details {open}`   |
| `CodeGroup`        | children                        | `::: code-group` wrapper           |
| `FrontmatterBlock` | format, literal                 | YAML `---` block                   |
| `TocToken`         | —                               | `[[toc]]` placeholder              |
| `MathBlock`        | literal                         | `$$...$$` display math             |

### Inline Nodes

| Node            | Key Fields                  | Notes                               |
| --------------- | --------------------------- | ----------------------------------- |
| `Text`          | literal                     | Plain text run                      |
| `SoftBreak`     | —                           | Newline within paragraph            |
| `HardBreak`     | —                           | `\\` or two trailing spaces         |
| `Code`          | literal, languageHint       | Optional `{:lang}` hint             |
| `Emphasis`      | inlines                     | `*` or `_`                          |
| `Strong`        | inlines                     | `**` or `__`                        |
| `Link`          | destination, title, inlines | `[text](url)` or reference          |
| `Image`         | destination, title, alt     | `![alt](url)`                       |
| `HtmlInline`    | literal                     | Inline raw HTML                     |
| `Autolink`      | destination                 | `<url>` or GFM autolink             |
| `Strikethrough` | inlines                     | GFM `~~text~~`                      |
| `Emoji`         | shortcode                   | `:tada:` → resolved name            |
| `MathInline`    | literal                     | `$...$` inline math                 |
| `CodeMarker`    | kind, line                  | `[!code focus]`, `[!code --]`, etc. |

### MDX Nodes

| Node            | Key Fields                         | Notes                           |
| --------------- | ---------------------------------- | ------------------------------- |
| `MdxJsxElement` | name, attrs, children, selfClosing | `<Component />` or `<C>...</C>` |
| `MdxEsmImport`  | specifiers, source                 | `import X from 'y'`             |
| `MdxEsmExport`  | declaration                        | `export const meta = ...`       |
| `MdxExpression` | expression                         | `{variable}` inline expressions |

### Common Fields

All nodes share:

- `sourceSpan`: byte offset range into original input, plus start/end line and column.

`sourceSpan` is authoritative for diagnostics and downstream slicing. Literal string fields are convenience views and must never be required for semantic correctness.

Node origin is determined by the `SumType` variant itself — core CommonMark nodes are distinct types from extension nodes (e.g., `CustomContainer` is inherently a VitePress extension, `Strikethrough` is GFM). No runtime origin tag is needed.

### Representation

Nodes are plain structs composed via `std.sumtype.SumType` — no classes, no GC. Child lists use `SmallBuffer` arrays that fall back to arena allocation when the inline buffer overflows.

```d
import std.sumtype : SumType;

struct SourceSpan
{
    uint offset;
    uint length;
    // Line and column numbers are computed lazily on demand by querying the SourceMap
}

// --- Block node structs ---

struct Document       { SourceSpan span; AstNode*[] children; }
struct BlockQuote     { SourceSpan span; AstNode*[] children; }
struct ListBlock      { SourceSpan span; bool ordered; uint start; bool tight; AstNode*[] children; }
struct ListItem       { SourceSpan span; TaskStatus taskStatus; AstNode*[] children; }
struct Paragraph      { SourceSpan span; InlineNode[] inlines; }
struct Heading        { SourceSpan span; ubyte level; const(char)[] customId; InlineNode[] inlines; }
struct ThematicBreak  { SourceSpan span; }
struct FencedCode     { SourceSpan span; const(char)[] infoString; CodeMeta metadata; const(char)[] literal; }
struct IndentedCode   { SourceSpan span; const(char)[] literal; }
struct HtmlBlock      { SourceSpan span; const(char)[] literal; }
struct TableBlock     { SourceSpan span; Alignment[] alignments; AstNode*[] children; }
struct TableRow       { SourceSpan span; bool isHeader; AstNode*[] children; }
struct TableCell      { SourceSpan span; Alignment alignment; InlineNode[] inlines; }
struct CustomContainer{ SourceSpan span; const(char)[] type; const(char)[] title; AstNode*[] children; }
struct CodeGroup      { SourceSpan span; AstNode*[] children; }
struct FrontmatterBlk { SourceSpan span; const(char)[] format; const(char)[] literal; }
struct TocToken       { SourceSpan span; }
struct MathBlock      { SourceSpan span; const(char)[] literal; }

// --- Inline node structs ---

struct Text           { SourceSpan span; const(char)[] literal; }
struct SoftBreak      { SourceSpan span; }
struct HardBreak      { SourceSpan span; }
struct Code           { SourceSpan span; const(char)[] literal; const(char)[] languageHint; }
struct Emphasis       { SourceSpan span; InlineNode[] inlines; }
struct Strong         { SourceSpan span; InlineNode[] inlines; }
struct Link           { SourceSpan span; const(char)[] destination; const(char)[] title; InlineNode[] inlines; }
struct Image          { SourceSpan span; const(char)[] destination; const(char)[] title; const(char)[] alt; }
struct HtmlInline     { SourceSpan span; const(char)[] literal; }
struct Autolink       { SourceSpan span; const(char)[] destination; }
struct Strikethrough  { SourceSpan span; InlineNode[] inlines; }
struct Emoji          { SourceSpan span; const(char)[] shortcode; }
struct MathInline     { SourceSpan span; const(char)[] literal; }
struct CodeMarker     { SourceSpan span; MarkerKind kind; uint line; }

// --- MDX node structs ---

struct MdxJsxElement  { SourceSpan span; const(char)[] name; bool selfClosing; AstNode*[] children; }
struct MdxEsmImport   { SourceSpan span; const(char)[] source; }
struct MdxEsmExport   { SourceSpan span; const(char)[] declaration; }
struct MdxExpression  { SourceSpan span; const(char)[] expression; }

// --- Composite SumTypes ---

alias InlineNode = SumType!(
    Text, SoftBreak, HardBreak, Code, Emphasis, Strong,
    Link, Image, HtmlInline, Autolink, Strikethrough,
    Emoji, MathInline, CodeMarker, MdxExpression,
);

alias BlockNode = SumType!(
    Document, BlockQuote, ListBlock, ListItem, Paragraph,
    Heading, ThematicBreak, FencedCode, IndentedCode,
    HtmlBlock, TableBlock, TableRow, TableCell,
    CustomContainer, CodeGroup, FrontmatterBlk, TocToken,
    MathBlock, MdxJsxElement, MdxEsmImport, MdxEsmExport,
);

alias AstNode = SumType!(InlineNode, BlockNode);
```

## Performance Constraints

1. O(n) parse time for typical and adversarial documents.
2. No catastrophic backtracking; avoid regex-heavy critical paths.
3. Low allocation strategy: arenas and reusable buffers.
4. Separate parse and render passes to preserve composability.
5. CTFE-compatible core fallback paths to allow compile-time parsing and HTML generation.

## Allocation Strategy and Determinism

The parser separates ownership of source text from allocation of parser state so each can be tuned independently.

### Allocator Roles

1. **Source materialization allocator**: contiguous UTF-8 buffer used when copying/decoding/rewrite is required.
2. **Parse arena allocator**: events, AST nodes, and variable-sized parser structures.
3. **Scratch allocator/buffer**: temporary rewrite and normalization storage.

By default, ergonomic wrappers can use GC-backed allocation. Deterministic and `@nogc` paths provide explicit allocators.

Allocator hooks use `std.experimental.allocator`-style primitives. `allocate` is required; `deallocate` is optional.

### Arena Allocator

AST nodes are allocated from a per-parse arena allocator (using `std.experimental.allocator` patterns). The arena is bulk-freed when the parse result is released, avoiding per-node deallocation overhead.

### Event Stream Storage

The event stream uses a growable `SmallBuffer`-like array. Events are appended sequentially with no per-event heap allocation in the common case. When the inline buffer is exhausted, the array falls back to arena-backed growth.

### Input Materialization Rules

1. `ubyte` inputs that are already contiguous may still require owned materialization to store UTF-8-decoded `char` text.
2. Strict input ranges are always materialized before parsing to guarantee deterministic rescans and span validity.
3. Preprocessor rewrites allocate owned storage for rewritten segments; unaffected regions may remain borrowed in rope form.
4. Borrowing is only used when span-to-source mapping remains valid without copying.
5. Under `BorrowPolicy.auto`, borrow-to-owned fallback is silent in release; implementations may expose debug instrumentation via `debug pragma(msg, ...)`.

### Zero-Copy and Span-First Access

When borrowing is valid, textual data is exposed as zero-copy slices into the source buffer. Regardless of ownership mode, spans remain the canonical reference and permit explicit caller-controlled copying.

### Parser State Reuse

The parser struct is designed for reuse across multiple documents. Internal buffers (delimiter stack, open block stack, event array) are cleared but not freed between invocations, amortizing allocation costs across batch processing.

### `@nogc` API Surface

- Allocator-based parse paths (`parseOwned`, `parse` with explicit allocator) are designed to be fully `@nogc`.
- The event stream and AST are fully `@nogc`-compatible.
- Convenience functions like `toHtml()` returning `string` may allocate via the GC for ergonomics.
- Users needing `@nogc` rendering use the output-range-based `renderHtml(ref Writer)` overload.

### DbI-Based Safety and Zero-Cost Paths

Memory management customizations follow DbI capability detection, not mandatory interfaces.

1. If an allocator hook provides required primitives (`allocate`, optional `deallocate`), parser code selects allocator-backed paths.
2. If allocator/hook is `void`, compiler removes unused branches and defaults to baseline behavior.
3. Public APIs are best-effort `@safe`, `pure`, `nothrow`, and `@nogc`, with capability-gated fallbacks documented per overload.

## Safety and Limits

1. Hard caps for maximum nesting depth, include depth, and file size.
2. Explicit option for dangerous HTML/protocols.
3. Default-safe URL and raw HTML handling.

## DbI Extension System (Shell With Hooks)

The parser core is the shell; extensions are hooks with optional capabilities. This follows the DbI shell-with-hooks pattern from the [DbI guidelines][dbi-guidelines].

### Required Hook Primitive

An extension must provide only identity and registration metadata:

```d
struct MyExtension
{
    enum name = "my_extension";
    enum priority = 100;  // lower = earlier in chain
}
```

### Optional Hook Primitives

Each hook primitive has a specific signature and purpose. Absence of any hook preserves baseline correctness.

#### 1. `preprocessDocument`

Mutates the input before block parsing begins. Use for include/snippet expansion, frontmatter extraction, or input rewriting.

```d
void preprocessDocument(ref ParseContext ctx);
```

#### 2. `tryStartBlock`

Recognizes new block-level constructs. Called when the core parser cannot match a line to a known block type. Returns a `BlockStart` if the extension claims the line, or `null` to defer.

```d
Nullable!BlockStart tryStartBlock(ref LineScanner scanner, ref BlockStack openBlocks);
```

#### 3. `tryParseInline`

Parses extension-specific inline tokens (e.g., emoji shortcodes, math delimiters). Called at each character position during inline parsing. Returns an `InlineNode` if matched, or `null` to defer.

```d
Nullable!InlineNode tryParseInline(ref InlineScanner scanner, ref DelimiterStack delims);
```

#### 4. `onPostParse`

Transforms the event stream after parsing is complete. Use for heading anchor generation, TOC assembly, or cross-reference resolution.

```d
void onPostParse(ref EventStream events);
```

#### 5. `onRenderNode`

Provides custom rendering for specific node types. Returns `true` if the hook handled rendering (suppressing the default renderer), `false` to fall through.

```d
bool onRenderNode(in AstNode node, ref Writer writer);
```

#### 6. `onError`

Handles parse errors with custom recovery. Returns an `ErrorAction` indicating whether to skip, recover, or abort.

```d
ErrorAction onError(ParseError error);
```

### ParseContext

```d
struct ParseContext
{
    const(char)[] input;          // Current normalized input view (borrowed or owned)
    SmallBuffer!(char, 4096) buf; // Scratch buffer for rewriting
    string sourcePath;            // File path for diagnostics
    Limits limits;                // Active parser limits
    DiagnosticSink diagnostics;   // Error/warning accumulator
}
```

### Capability Detection

Capability checks are centralized in traits; no scattered ad-hoc `__traits(compiles, ...)`.

```d
enum bool hasPreprocessDocument(E, Ctx) = __traits(compiles, {
    E e = E.init;
    Ctx c = Ctx.init;
    e.preprocessDocument(c);
});

enum bool hasTryStartBlock(E, Scanner, Stack) = __traits(compiles, {
    E e = E.init;
    Scanner s = Scanner.init;
    Stack st = Stack.init;
    auto r = e.tryStartBlock(s, st);
});

enum bool hasTryParseInline(E, Scanner, Delims) = __traits(compiles, {
    E e = E.init;
    Scanner s = Scanner.init;
    Delims d = Delims.init;
    auto r = e.tryParseInline(s, d);
});

// ... analogous traits for onPostParse, onRenderNode, onError
```

### Multi-Extension Composition

Multiple extensions are composed as a tuple. The parser iterates extensions in priority order (lowest `priority` value first). For hooks like `tryStartBlock`, the first extension to return a non-null result wins. For hooks like `onPostParse`, all extensions run in priority order.

```d
alias Extensions = AliasSeq!(FrontmatterExt, ContainerExt, EmojiExt);

struct MarkdownOptions(Hook = void, Alloc = void)
{
    // When Hook is void, no extension overhead.
    // When Hook is a tuple, extensions compose.
    // Allocator selection remains orthogonal and is controlled separately.
}
```

### Dispatch Precedence

1. Full override hook (if present) — extension takes complete control.
2. Event-specific hook — extension observes/handles at a critical point.
3. Core fallback path — baseline CommonMark behavior.

A `void` hook compiles to the pure baseline with zero overhead (the `void` hook test from [DbI guidelines][dbi-guidelines]).

### Stateless Optimization

Extensions without state are not stored in the parser struct:

```d
static if (stateSize!Hook > 0)
    Hook hook;
else
    alias hook = Hook;
```

## API Surface

### Profile and Feature Flags

```d
enum Profile
{
    commonmark_strict,
    gfm,
    vitepress_compatible,
    nextra_compatible,
    custom,
}

struct FeatureFlags
{
    bool tables = false;
    bool strikethrough = false;
    bool taskLists = false;
    bool autolinks = false;
    bool customContainers = false;
    bool emojiShortcodes = false;
    bool tocToken = false;
    bool mathSyntax = false;
    bool codeImport = false;
    bool markdownInclude = false;
    bool codeGroups = false;
    bool githubAlerts = false;
    bool headingAnchors = false;
    bool customHeadingIds = false;
    bool fenceMetadata = false;
    bool codeMarkers = false;
    bool mdxSyntax = false;
    // Profile presets populate these flags; custom allows manual selection.
}
```

### Limits

```d
struct Limits
{
    uint maxNestingDepth = 128;
    uint maxIncludeDepth = 8;
    size_t maxInputBytes = 16 * 1024 * 1024;  // 16 MiB
    uint maxTokenCount = 0;                    // 0 = unlimited
}
```

### Ownership and Allocation Controls

```d
enum BorrowPolicy
{
    auto,
    requireBorrow,
    requireCopy,
}

enum SourceOwnership
{
    borrowed,
    owned,
}

enum Utf8ErrorMode
{
    replace,     // replace invalid sequences (U+FFFD)
    strictFail,  // emit error and abort parse
}

struct SourceStorage
{
    SourceOwnership ownership;
    const(char)[] text;  // Borrowed caller memory or parser-owned normalized storage
}

struct RawByteStorage
{
    SourceOwnership ownership;
    const(ubyte)[] bytes;  // Preserved original bytes for tooling/debug workflows
}

enum HeadingIdSyntaxPreference
{
    vitepressBraceFirst,
    nextraBracketFirst,
}
```

### Parser Options

```d
struct MarkdownOptions(Hook = void, Alloc = void)
{
    Profile profile = Profile.commonmark_strict;
    FeatureFlags features;
    Hook hook;
    bool sourcePos = true;
    bool safeMode = true;
    Limits limits;
    Utf8ErrorMode utf8ErrorMode = Utf8ErrorMode.replace;
    HeadingIdSyntaxPreference headingIdPreference = HeadingIdSyntaxPreference.vitepressBraceFirst;

    // Optional allocator hook. `void` means use baseline allocation path.
    static if (!is(Alloc == void))
        Alloc allocator;

    // Borrow policy is extracted at compile-time from the Hook, defaulting to auto.
    enum BorrowPolicy borrowPolicy = () {
        static if (__traits(compiles, Hook.borrowPolicy))
            return Hook.borrowPolicy;
        else
            return BorrowPolicy.auto;
    }();
}
```

### Parse Result

```d
struct ParseResult
{
    EventStream events;         // Primary output: flat event sequence
    SourceStorage source;       // Borrowed/owned normalized source text (or rope view)
    RawByteStorage rawBytes;    // Preserved original input bytes
    SourceMap sourceMap;        // Byte offset → line/column mapping
    DiagnosticList diagnostics; // Warnings and recoverable errors
}
```

### Render Options

```d
struct RenderOptions
{
    bool unsafeHtml = false;    // Pass through raw HTML and dangerous URLs
    bool sourcePos = false;     // Emit data-sourcepos attributes
    bool softBreakAs = '\n';    // Soft break rendering: '\n', ' ', or "<br />"
}
```

### Primary API

```d
/// Basic hook that forces requireBorrow policy at compile-time
struct RequireBorrowHook
{
    enum borrowPolicy = BorrowPolicy.requireBorrow;
}

/// Basic hook that forces requireCopy policy at compile-time
struct RequireCopyHook
{
    enum borrowPolicy = BorrowPolicy.requireCopy;
}

/// Parse markdown from any input range of char or ubyte.
/// - `char` ranges are assumed valid UTF-8.
/// - `ubyte` ranges are UTF-8 decoded according to `utf8ErrorMode`.
/// - Ownership is controlled by BorrowPolicy (auto by default unless overridden in Hook).
ParseResult parse(R, Hook = void, Alloc = void)(
    R input,
    MarkdownOptions!(Hook, Alloc) opts = MarkdownOptions!(Hook, Alloc)(),
)
if (isInputRange!R && (is(ElementType!R : const(char)) || is(ElementType!R : const(ubyte))));

/// Hard guarantee: no source copy and slice-only inputs.
/// Caller must request explicit borrow semantics either via `RequireBorrowHook` or their own Hook.
ParseResult parseBorrowed(S, Hook = RequireBorrowHook)(
    S input,
    MarkdownOptions!(Hook, void) opts = MarkdownOptions!(Hook, void)()
)
if ((is(S == const(char)[]) || is(S == immutable(char)[]) || is(S == const(ubyte)[]) || is(S == immutable(ubyte)[])) &&
    opts.borrowPolicy == BorrowPolicy.requireBorrow);

/// Hard guarantee: source is owned by ParseResult storage using provided allocator.
ParseResult parseOwned(R, Hook = RequireCopyHook, Alloc)(
    R input,
    ref Alloc allocator,
    MarkdownOptions!(Hook, Alloc) opts = MarkdownOptions!(Hook, Alloc)(
        allocator: allocator,
    ),
)
if (isInputRange!R && (is(ElementType!R : const(char)) || is(ElementType!R : const(ubyte))) &&
    opts.borrowPolicy == BorrowPolicy.requireCopy);

/// Resolve a span into text; callers choose whether to keep borrowing or copy.
const(char)[] sourceSlice(in ParseResult result, in SourceSpan span);

/// Resolve a span into original raw bytes.
const(ubyte)[] rawSlice(in ParseResult result, in SourceSpan span);

/// Render events to HTML using an output range (Writer).
ref Writer renderHtml(Writer, Hook = void)(
    in ParseResult result,
    return ref Writer writer,
    in RenderOptions opts = RenderOptions(),
);

/// Convenience: render to allocated string.
string toHtml(Hook = void)(
    in ParseResult result,
    in RenderOptions opts = RenderOptions(),
);

/// Build a tree-structured AST from the event stream (optional).
AstNode buildAst(in ParseResult result);
```

## Verification and Benchmarking

The complete strategy is defined in [Markdown Testing Strategy][markdown-testing-spec].

At a high level:

1. Validation is profile-aware (`commonmark_strict`, `gfm`, `vitepress_compatible`, `nextra_compatible`, `custom`) and tiered (normative conformance, compatibility, differential, adversarial/fuzz).
2. Fixture ingestion is deterministic and provenance-aware (source URL, commit SHA, license metadata).
3. Comparison uses canonicalized HTML with explicit profile-scoped override policy for ambiguous cases.
4. Compatibility packs explicitly cover both VitePress and Nextra markdown/MDX semantics without conflating framework-runtime behavior.
5. Benchmarking compares major JavaScript, Rust, C, and Go implementations under pinned, reproducible fairness constraints.
6. Benchmark execution happens in a dedicated markdown benchmarking devshell with pinned Rust, Go, and Node toolchains.

## Success Criteria

1. 100% CommonMark conformance in strict profile.
2. 100% pass on selected VitePress compatibility packs in `vitepress_compatible` profile.
3. 100% pass on selected Nextra compatibility packs in `nextra_compatible` profile.
4. No known crash or unbounded-time cases in adversarial suite.
5. Performance in top tier of CommonMark-compliant implementations for at least parse-only throughput.

## Milestones

1. M1: Core parser skeleton + CommonMark block/inline baseline.
2. M2: CommonMark full compliance + sourcepos + safety defaults.
3. M3: Extension shell (DbI) + GFM primitives.
4. M4: Full VitePress-compatible feature set.
5. M5: Corpus ingestion automation and differential dashboard.
6. M6: Benchmark harness and optimization rounds.

## Risks and Mitigations

1. Divergent extension semantics across ecosystems; mitigate with profile-scoped expectations.
2. Include/snippet features introducing IO/security risk; mitigate with sandboxed path policy and explicit opts.
3. Benchmark bias across runtimes; mitigate with transparent adapters and separate in-process vs CLI metrics.
4. Extension complexity regressing performance; mitigate with optional hooks and zero-cost disabled branches.

## Decisions and Open Questions

### Resolved

1. **Vue component interpolation**: markdown-stage only. Full Vue SFC/component interpolation is a non-goal for the parser; it belongs to the VitePress build pipeline.
2. **Math rendering**: token-only. The parser emits `MathInline` and `MathBlock` nodes with raw LaTeX content. Downstream renderers handle MathJax/KaTeX integration via `onRenderNode` hooks.
3. **Default profile**: `commonmark_strict`. VitePress and Nextra features are opt-in via their respective profiles. This ensures the parser is safe and predictable by default.
4. **Benchmark environment reproducibility**: use a dedicated benchmark devshell with pinned Rust, Go, and Node toolchains.
5. **Heading ID precedence**: configurable via `HeadingIdSyntaxPreference`; default is VitePress brace syntax (`{#my-anchor}`) first.
6. **BorrowPolicy auto for `const(T)[]`**: borrow-first.
7. **Include preprocessing ownership**: mixed ownership is allowed via rope segments (borrowed + owned) with explicit lifetime constraints.
8. **`parseBorrowed` policy enforcement**: slice-only API with static rejection of `BorrowPolicy.auto`; `parse(...)` handles auto fallback.
9. **UTF-8 error behavior**: configurable (`replace`, `strictFail`).
10. **Auto borrow fallback visibility**: debug-only instrumentation via `debug pragma(msg, ...)`.
11. **Allocator interface**: `std.experimental.allocator` primitives (`allocate` required, `deallocate` optional).
12. **Raw source preservation**: `ParseResult` preserves original raw bytes.

### Open

1. None currently. New decisions should be appended here and promoted to **Resolved** once finalized.

## Glossary

- **Event stream**: a flat sequence of typed events (e.g., `EnterParagraph`, `Text`, `ExitParagraph`) representing parsed document structure. Primary output of the parser; more cache-friendly than a tree.
- **AST**: Abstract Syntax Tree — a tree-structured representation built from the event stream when consumers need parent/child navigation or tree transformations.
- **Arena**: a bulk-allocation strategy where all allocations share a single memory region freed together, avoiding per-object deallocation overhead.
- **SourceSpan**: a byte-offset/length pair (with line/column metadata) that identifies source text without borrowing string memory directly.
- **Source ownership**: whether `ParseResult` references caller memory (`borrowed`) or parser-managed storage (`owned`).
- **Source rope**: a composite source representation made of borrowed and owned text segments with explicit lifetime constraints.
- **Hook**: an optional capability provided by an extension type, discovered at compile time via DbI capability traits.
- **Shell**: the parser core that provides baseline CommonMark behavior; hooks extend it without modifying its source.
- **Profile**: a named feature configuration preset (`commonmark_strict`, `gfm`, `vitepress_compatible`, `nextra_compatible`, `custom`).
- **Capability trait**: a compile-time predicate (e.g., `hasPreprocessDocument`) that detects whether a type provides a specific hook.
- **Delimiter run**: a sequence of delimiter characters (`*`, `_`) used in the CommonMark emphasis algorithm; processed via a stack-based algorithm that guarantees O(n) complexity.
- **Lazy continuation**: a CommonMark rule allowing paragraph text to continue inside containers (block quotes, list items) without repeating container markers on every line.

## Reference Links

[markdown-testing-spec]: ./TESTING.md
[code-style-guide]: ../../guidelines/code-style.md
[functional-guidelines]: ../../guidelines/functional-declarative-programming-guidelines.md
[dbi-intro]: ../../guidelines/design-by-introspection-00-intro.md
[dbi-guidelines]: ../../guidelines/design-by-introspection-01-guidelines.md
[sean-parent-index]: ../../research/sean-parent/index.md
[sean-local-reasoning]: ../../research/sean-parent/local-reasoning.md
[sean-contracts]: ../../research/sean-parent/contracts.md
